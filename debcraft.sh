#!/bin/bash

# stop on errors
set -e

# @TODO: pipefail not in POSIX
set -o pipefail

# show commands (debug)
#set -x

if [ -n "$PKG" ] && [ -n "$CONTAINER" ]
then
  echo "Building package/dir $PKG in container $CONTAINER (from environtment)"
elif [ -f ./.env ]
then
  # shellcheck disable=SC2086,SC1091
  . ./.env
  echo "Building package/dir $PKG in container $CONTAINER (from .env file)"
else
  if [ -z "$PKG" ]
  then
    PKG="$(basename "$(pwd)" | sed s/pkg-//)"
    echo "No PKG defined, defaulting to '$PKG' based on directory name"
  fi

  if [ -z "$CONTAINER" ]
  then
    CONTAINER="debian-sid-build-env"
    echo "No CONTAINER defined, defaulting container '$CONTAINER'"
  fi
fi

if [ -z "$1" ]
then
  echo "ERROR: This script must be called with an argument!"
  exit 1
fi

if [ ! -d "$PKG/.git" ]
then
  echo "ERROR: No directory or git repository in $PKG"
  exit 1
fi

# Set git commit id and name for later use
COMMIT_ID=$(git -C "$PKG/.git" log -n 1 --oneline | cut -d ' ' -f 1)
# Strip branch paths and any slashes so version string is clean
BRANCH_NAME=$(git -C "$PKG/.git" symbolic-ref HEAD | sed 's|.*heads/||' | sed 's|/|.|g')

# Use environment if set, otherwise use nice defaults
DEB_BUILD_OPTIONS="${DEB_BUILD_OPTIONS:-parallel=4 nocheck noautodbgsym}"
echo "Running with DEB_BUILD_OPTIONS=\"$DEB_BUILD_OPTIONS\""

# Clean up old files
rm -f -- *.changes *.dsc *.deb

build_in_container() {
  # Reset ccache stats, silently
  CCACHE_DIR=./buildout/ccache ccache -z -s

  # Clean tmp directory
  rm -f buildout/*.*

  # Use custom build command if given
  if [ -n "$*" ]
  then
    COMMAND="$*"
  else
    COMMAND="gbp buildpackage"
  fi

  echo # Space to make output more readable
  echo "----------------------------------------------------------------------"
  echo "==> $COMMAND"

  # Run build inside a Podman image with build dependencies defined in a Podmanfile
  # --tty needed for session to have colors automatically
  # --interactive needed for Ctrl+C to cancel build and stop container (and not
  # just exit tty)
  # NOTE!: If build fails, script fails here (due to set pipefail) and there
  # will be no notifications or sounds to user.
  # shellcheck disable=SC2086
  podman run --name deb-builder \
      --interactive --tty --rm \
      --shm-size=1G \
      --cpus=4 \
      -v "${PWD}/buildout":/tmp/build -v "${PWD}/buildout/ccache":/.ccache \
      -v "${PWD}/$PKG":/tmp/build/source -w /tmp/build/source \
      -e DEB_BUILD_OPTIONS="$DEB_BUILD_OPTIONS" -e CCACHE_DIR=/.ccache \
      "$CONTAINER" \
      $COMMAND | tee "build-$COMMIT_ID-$BRANCH_NAME.log"

  # Podman has user mapping by default. If using Docker, add '--user="$(id -u)"'
  # in the command above to enable user mapping.
  echo "----------------------------------------------------------------------"
  echo # Space to make output more readable

  # Show ccache stats
  CCACHE_DIR=./buildout/ccache ccache -s

  # Copy generated files to parent directory after successful run
  if cp -ra buildout/*.* . > /dev/null 2>&1
  then

    # clean up any old filelist from same commit
    rm -f "filelist-$COMMIT_ID-$BRANCH_NAME.log"
    for package in *.deb
    do
      echo "$package" | cut -d '_' -f 1 >> \
        "filelist-$COMMIT_ID-$BRANCH_NAME.log"
      dpkg-deb -c "$package" | awk '{print $1 " " $2 " " $6 " " $7 " " $8}' | sort -k 3 >> \
        "filelist-$COMMIT_ID-$BRANCH_NAME.log"
      echo "------------------------------------------------" >> \
        "filelist-$COMMIT_ID-$BRANCH_NAME.log"
    done
    echo "filelist-$COMMIT_ID-$BRANCH_NAME.log created"

    # Run Lintian, but don't exit on errors since 'unstable' and 'sid' releases
    # will likely always emit errors if package complex enough
    podman run -it --rm --user="$(id -u)" --shm-size=1G -v "${PWD}:/package" -w /package "$CONTAINER" \
      lintian -EvIL +pedantic --profile=debian --color=never \
      ./*.changes | tee "lintian-$COMMIT_ID-$BRANCH_NAME.log" || true
    # Don't use color, otherwise logs become unreadable and diffs messy

   # NOTE! Lintian is Perl and therefore installing the latest Lintian version on any older
   # Debian/Ubuntu distro generally works well. Download and install the latest version from
   # https://packages.debian.org/sid/all/lintian/download
   # NOTE! ..but not on Sid in 2023, so running Lintian inside container..

  fi

}


if [ "$1" = "full" ]
then
  # Use subshell to avoid having cd .. back
  (cd "$PKG"; git reset --hard; git clean -fdx)

  # -I, --tar-ignore (passed to dpkg-source) by itself adds default --exclude options that
  # will filter out control files and directories of the most common revision
  # control systems, backup and swap files and Libtool build output directories
  # -i, --diff-ignore (passed to dpkg-source) by  itself  enables  this  setting
  # with a default regex that will filter out control files and directories of
  # the most common revision control systems, backup and swap files and Libtool
  # build output directories
  # Notifications cannot be emitted from inside the Podman container, so don't
  # bother running with --git-notify.

  # Regular build for Salsa-CI maintained Debian packages
  # Internally runs 'debuild -i -I'
  build_in_container gbp buildpackage --git-builder='debuild --no-lintian --no-sign -i -I'

elif [ "$1" = "source" ] || [ "$1" = "src" ]
then
  # Use subshell to avoid having cd .. back
  (cd "$PKG"; git reset --hard; git clean -fdx)

  # Use subshell to avoid having cd .. back
  # Use -S so all tools (dpkg-build, dpkg-source) see it. Using --build=source
  # would not bee enough.
  (cd "$PKG"; gbp buildpackage --git-notify=on --git-builder="debuild --no-lintian -i -I" -S -d)

  # Show source-only Lintian info without saving it in a file
  # Don't fail if there are errors, as we often want to proceed to test uploads anyway
  lintian -EvIL +pedantic --profile=debian --color=always ./*.changes || true

elif [ "$1" = "rebuild" ]
then
  # Minimal cleanup for quick rebuild of binary packages
  (cd $PKG; dh_prep --verbose)
  (cd $PKG; dh_clean --verbose) # this is excess but needed to re-trigger mariadb builds
  # Quick rebuild
  # --build=any,all is without 'source', thus don't generate tar.xz and run faster
  # @TODO: --no-pre-clean runs 'debian/rules binary' without 'debian/rules override_dh_auto_configure'
  #run_in_container fakeroot debian/rules override_dh_auto_configure # PKG_CONFIG missing
  #run_in_container fakeroot debian/rules override_dh_auto_build # always rebuilds rocksdb etc
  #run_in_container fakeroot debian/rules override_dh_auto_install # always rebuilds rocksdb etc
  # does not find anymore usr/lib/mysql/plugin/ha_archive.so, usr/lib/mysql/plugin/ha_blackhole.so, usr/lib/mysql/plugin/ha_federatedx.so
  #run_in_container fakeroot debian/rules override_dh_auto_c
  #run_in_container fakeroot debian/rules build
  #run_in_container dh build --verbose
  #run_in_container fakeroot dh install --verbose # compat level 9
  build_in_container dpkg-buildpackage --no-sign --build=any,all
  # --no-pre-clean

else
  # shellcheck disable=SC2086,SC2048
  build_in_container $*

  # Tips: https://www.debian.org/doc/manuals/maint-guide/build.en.html#quickrebuild
  # E.g.:
  #   man debhelper -> list of steps
  #   dh --list
  #   dh binary --no-act
  #   dh build
  #   dh_builddeb
  #   fakeroot debian/rules override_dh_auto_configure
  #   fakeroot debian/rules binary
fi


# Suggest upload only if *.dsc built
if ls ./*.dsc > /dev/null 2>&1
then
  DSC="$(ls ./*.dsc)"

  # Default to personal PPA if no other set
  if [ -z "$PPA" ]
  then
    PPA="ppa:$(id -un)/ppa"
  fi

  SERIES=$(cd "$PKG"; dpkg-parsechangelog -S distribution)

  # Strip away any -updates or -security components before upload
  SERIES=$(echo "$SERIES" | sed 's/-updates//g' | sed 's/-security//g')

  # Current Launchpad Debian Sid equivalent
  if [ "$SERIES" = 'unstable' ] || [ "$SERIES" = 'sid' ] || [ "$SERIES" = 'UNRELEASED' ] || [ "$SERIES" = 'experimental' ]
  then
    SERIES='noble'
  fi

  # Historical equivalents
  case $SERIES in
    bookworm)
      # June 2023
      SERIES='lunar'
      ;;
    bullseye)
      # August 2021
      SERIES='hirsute' # or impish
      ;;
    buster)
      # July 2019
      SERIES='disco' # or eoan
      ;;
    stretch)
      # June 2017
      SERIES='zesty' # or artful
      ;;
  esac


  # The Launchpad upload cannot have any extra Debian/Ubuntu version string
  # components, therefore convert all extra characters to simply dots.
  BRANCH_NAME=${BRANCH_NAME//-/.}

  # Notify
  notify-send --icon=/usr/share/icons/Humanity/actions/48/dialog-apply.svg \
    --urgency=low "Build of $PKG at $COMMIT_ID (branch $BRANCH_NAME) ready"
  paplay --volume=65536 /usr/share/sounds/freedesktop/stereo/complete.oga

  echo # Space to make output more readable

  # POSIX sh does not support 'read -p' so run int via bash
  read -r -p "Press Ctrl+C to cancel or press enter to proceed with:
  backportpackage -y -u $PPA -d $SERIES -S ~$(date '+%s').$COMMIT_ID+$BRANCH_NAME $DSC
  "

  # Upload to Launchpad
  backportpackage -y -u "$PPA" -d "$SERIES" \
    -S "~$(date '+%s').$COMMIT_ID.$BRANCH_NAME" "$DSC"
fi


# @TODO: Compare with diffoscope
# - needs to have something to compare to
# - filenames must be identical, otherwise end result is just a filename comparison
# - meld on uncompressed .deb dirs might be more interactive?
# - debdiff might also work well
# podman run --rm -t -w $(pwd) -v $(pwd):$(pwd):ro       registry.salsa.debian.org/reproducible-builds/diffoscope --exclude-directory-metadata=yes --no-progress --html - master compare > report.html
