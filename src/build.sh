#!/bin/bash

# Docker build script
# Copyright (c) 2017 Julian Xhokaxhiu
# Copyright (C) 2017-2018 Nicola Corna <nicola@corna.info>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

function out() {
  echo ">> [$(date)] $@"
}

function die() {
  out "$@"
  exit 1
}

# Execute a user script
function exec_user_script() {
  local script="${BUILD_SCRIPTS_PATH}/userscripts/${1}.sh"
  [ ! -f "$script" ] && return
  if stat -c '%U' "$script" | grep -s "${BUILD_USER}"; then
    out "WARNING: User script not owned by build user. Skipping insecure script..."
    return
  fi
  if stat -c '%a' "$script" | grep -qv "..0"; then
    out "WARNING: User script is accessible by users other than the build user. Skipping insecure script..."
    return
  fi
  shift
  out "Executing '$script'"
  $script $@
}

# Check if a user script is present
function user_script_exists() {
  local script="${BUILD_SCRIPTS_PATH}/userscripts/${1}.sh"
  if [ -f "$script" ]; then
    echo true
    return 0
  else
    echo false
    return 1
  fi
}

# If requested, clean the OUT dir in order to avoid clutter
function wipe_outdir() {
  [ "$CLEAN_OUTDIR" != "true" ] && return

  out "Wiping output directory '$ZIP_DIR'"
  rm -rf "${ZIP_DIR:-should-not-happen}"
}

# If needed, migrate from the old SRC_DIR structure
function repo_migrate() {
  [ ! -d "$SRC_DIR/.repo" ] && return

  local BRANCH_DIR=$(repo info -o | sed -ne 's/Manifest branch: refs\/heads\///p' | sed 's/[^[:alnum:]]/_/g')
  BRANCH_DIR=${BRANCH_DIR^^}
  out "WARNING: old source dir detected, moving source from \"\$SRC_DIR\" to \"\$SRC_DIR/$BRANCH_DIR\""
  if [ -d "$BRANCH_DIR" ] && [ -z "$(ls -A "$BRANCH_DIR")" ]; then
    out "ERROR: $BRANCH_DIR already exists and is not empty; aborting"
  fi
  mkdir -p "$BRANCH_DIR"
  find . -maxdepth 1 ! -name "$BRANCH_DIR" ! -path . -exec mv {} "$BRANCH_DIR" \;
}

# Sync local source mirror
function mirror_sync() {
  [ "$LOCAL_MIRROR" != "true" ] && return

  out "Syncing mirror repository" | tee -a "$REPO_LOG"
  pushd "$MIRROR_DIR" &>> "$DEBUG_LOG"
  repo sync --force-sync --no-clone-bundle &>> "$REPO_LOG"
  popd &>> "$DEBUG_LOG"
}

# Download TheMuppets proprietary files manifest to current directory/repo
# Applies to: LineageOS only
function download_proprietary() {
  [ "$INCLUDE_PROPRIETARY" != "true" ] && return

  out "Downloading proprietary manifests"
  local themuppets_manifest=${1:-mirror/default.xml}
  wget -q -O .repo/local_manifests/proprietary.xml "https://raw.githubusercontent.com/TheMuppets/manifests/${themuppets_manifest}"
  /usr/bin/python3 "${BUILD_SCRIPTS_PATH}/build_manifest.py" \
    --remote "https://gitlab.com" \
    --remotename "gitlab_https" \
    "https://gitlab.com/the-muppets/manifest/raw/${themuppets_manifest}" .repo/local_manifests/proprietary_gitlab.xml
}

# Initialize local mirror
function mirror_init() {
  [ "$LOCAL_MIRROR" != "true" ] && return

  pushd "$MIRROR_DIR" &>> "$DEBUG_LOG"

  if [ ! -d .repo ]; then
    out "Initializing mirror repository" | tee -a "$REPO_LOG"
    yes | repo init -u ${MIRROR:-https://github.com/${ORG_NAME}/mirror} --mirror --no-clone-bundle -p linux &>> "$REPO_LOG"
  fi

  # Copy local manifests to the appropriate folder in order take them into consideration
  out "Copying '$LMANIFEST_DIR/*.xml' to '.repo/local_manifests/'"
  mkdir -p .repo/local_manifests
  rsync -a --delete --include '*.xml' --exclude '*' "$LMANIFEST_DIR/" .repo/local_manifests/

  rm -f .repo/local_manifests/proprietary.xml
  download_proprietary "mirror/default.xml"

  mirror_sync
  popd &>> "$DEBUG_LOG"
}

# Make source directory for the current branch and devices to build
function start_branch_build() {
  local branch=$1; shift
  local devices="$@"
  mkdir -p "$SRC_DIR/$BRANCH_DIR"
  out "Branch :  $branch"
  out "Devices:  $devices"
}

# Remove previous changes of vendor/cm, vendor/lineage, vendor/${VENDOR_NAME} and frameworks/base (if they exist)
function repo_reset() {
  for path in "vendor/cm" "vendor/lineage" "vendor/${VENDOR_NAME}" "frameworks/base"; do
    out "Resetting repo '$path'"
    if [ -d "$path" ]; then
      pushd "$path" &>> "$DEBUG_LOG"
      git reset -q --hard
      git clean -q -fd
      popd &>> "$DEBUG_LOG"
    fi
  done
}

# Initialize repo sources
function repo_init() {
  local branch=$1
  out "(Re)initializing branch repository" | tee -a "$REPO_LOG"
  if [ "$LOCAL_MIRROR" == "true" ]; then
    yes | repo init -u ${REPO:-https://github.com/${ORG_NAME}/android.git} --reference "$MIRROR_DIR" -b "$branch" &>> "$REPO_LOG"
  else
    yes | repo init -u ${REPO:-https://github.com/${ORG_NAME}/android.git} -b "$branch" &>> "$REPO_LOG"
  fi
}

# Copy local manifests to the appropriate folder in order take them into consideration
function copy_local_manifests() {
  out "Copying '$LMANIFEST_DIR/*.xml' to '.repo/local_manifests/'"
  mkdir -p .repo/local_manifests
  rsync -a --delete --include '*.xml' --exclude '*' "$LMANIFEST_DIR/" .repo/local_manifests/
}

# Copy all TheMuppets manifests into the repo.
# Applies to: LineageOS only
function copy_muppets_manifests() {
  rm -f .repo/local_manifests/proprietary.xml
  [ "$INCLUDE_PROPRIETARY" != "true" ] && return

  out "Copying proprietary manifests"
  local branch=$1
  if [[ $branch =~ .*cm\-13\.0.* ]]; then
    themuppets_branch=cm-13.0
  elif [[ $branch =~ .*cm-14\.1.* ]]; then
    themuppets_branch=cm-14.1
  elif [[ $branch =~ .*lineage-15\.1.* ]]; then
    themuppets_branch=lineage-15.1
  elif [[ $branch =~ .*lineage-16\.0.* ]]; then
    themuppets_branch=lineage-16.0
  elif [[ $branch =~ .*lineage-17\.0.* ]]; then
    themuppets_branch=lineage-17.0
  elif [[ $branch =~ .*lineage-17\.1.* ]]; then
    themuppets_branch=lineage-17.1
  else
    themuppets_branch=lineage-15.1
    out "Can't find a matching branch on github.com/TheMuppets, using $themuppets_branch"
  fi

  download_proprietary "$themuppets_branch/muppets.xml"
}

# Sync current branch repo
function repo_sync() {
  out "Syncing branch repository" | tee -a "$REPO_LOG"
  pushd "$SRC_DIR/$BRANCH_DIR" &>> "$DEBUG_LOG"
  repo sync -c --force-sync &>> "$REPO_LOG"
  popd &>> "$DEBUG_LOG"
}

# Get current android version from source
function get_android_version() {
  out "Getting android version from source"
  local branch=$1
  local platform_code=$(sed -n -e 's/^\s*DEFAULT_PLATFORM_VERSION := //p' build/core/version_defaults.mk)
  ANDROID_VERSION=$(sed -n -e 's/^\s*PLATFORM_VERSION\.'$platform_code' := //p' build/core/version_defaults.mk)
  if [ -z $ANDROID_VERSION ]; then
    die "Can't detect the android version"
  fi
  ANDROID_VERSION_MAJOR=$(cut -d '.' -f 1 <<< $ANDROID_VERSION)

  if [ "$ANDROID_VERSION_MAJOR" -lt "7" ]; then
    die "ERROR: $branch requires a JDK version too old (< 8); aborting"
  fi
}

# Get current vendor version
function get_vendor_version() {
  out "Getting vendor version from source"
  if [ "$ANDROID_VERSION_MAJOR" -ge "8" ]; then
    VENDOR="${VENDOR_NAME}"
  else
    VENDOR="cm"
  fi

  if [ ! -d "vendor/$VENDOR" ]; then
    die "ERROR: Missing \"vendor/$VENDOR\", aborting"
  fi

  DISTRO_VER_MAJOR=$(sed -n -e 's/^\s*PRODUCT_VERSION_MAJOR = //p' "vendor/$VENDOR/config/common.mk")
  DISTRO_VER_MINOR=$(sed -n -e 's/^\s*PRODUCT_VERSION_MINOR = //p' "vendor/$VENDOR/config/common.mk")
  DISTRO_VER="$DISTRO_VER_MAJOR.$DISTRO_VER_MINOR"
}

# Set up our overlay
function setup_vendor_overlay() {
  out "Setting up overlay"
  mkdir -p "vendor/$VENDOR/overlay/microg/"
  sed -i "1s;^;PRODUCT_PACKAGE_OVERLAYS := vendor/$VENDOR/overlay/microg\n;" "vendor/$VENDOR/config/common.mk"
}

# If needed, apply the microG's signature spoofing patch
function patch_signature_spoofing() {
  if [ "$SIGNATURE_SPOOFING" != "yes" ] || [ "$SIGNATURE_SPOOFING" != "restricted" ]; then
    return
  fi

  # Determine which patch should be applied to the current Android source tree
  local patch_name=""
  case $ANDROID_VERSION in
    4.4*  )    patch_name="android_frameworks_base-KK-LP.patch" ;;
    5.*   )    patch_name="android_frameworks_base-KK-LP.patch" ;;
    6.*   )    patch_name="android_frameworks_base-M.patch" ;;
    7.*   )    patch_name="android_frameworks_base-N.patch" ;;
    8.*   )    patch_name="android_frameworks_base-O.patch" ;;
    9*|9.*)    patch_name="android_frameworks_base-P.patch" ;; #not sure why 9 not 9.0 but here's a fix that will work until android 90
    10*   )    patch_name="android_frameworks_base-Q.patch" ;;
  esac

  if ! [ -z $patch_name ]; then
    pushd frameworks/base &>> "$DEBUG_LOG"
    if [ "$SIGNATURE_SPOOFING" == "yes" ]; then
      out "Applying the standard signature spoofing patch ($patch_name) to frameworks/base"
      out "WARNING: the standard signature spoofing patch introduces a security threat"
      patch --quiet -p1 -i "${BUILD_SCRIPTS_PATH}/signature_spoofing_patches/$patch_name"
    else
      out "Applying the restricted signature spoofing patch (based on $patch_name) to frameworks/base"
      sed 's/android:protectionLevel="dangerous"/android:protectionLevel="signature|privileged"/' "${BUILD_SCRIPTS_PATH}/signature_spoofing_patches/$patch_name" | patch --quiet -p1
    fi
    git clean -q -f
    popd &>> "$DEBUG_LOG"

    # Override device-specific settings for the location providers
    mkdir -p "vendor/$VENDOR/overlay/microg/frameworks/base/core/res/res/values/"
    cp "${BUILD_SCRIPTS_PATH}/signature_spoofing_patches/frameworks_base_config.xml" "vendor/$VENDOR/overlay/microg/frameworks/base/core/res/res/values/config.xml"
  else
    die "ERROR: can't find a suitable signature spoofing patch for the current Android version ($ANDROID_VERSION)"
  fi
}

function patch_unifiednlp() {
  [ "$SUPPORT_UNIFIEDNLP" != "true" ] && return

  # Determine which patch should be applied to the current Android source tree
  local patch_name=""
  case $ANDROID_VERSION in
    10*  )    patch_name="android_frameworks_base-Q.patch" ;;
  esac

  if ! [ -z $patch_name ]; then
    pushd frameworks/base &>> "$DEBUG_LOG"
      out "Applying location services patch"
      patch --quiet -p1 -i "${BUILD_SCRIPTS_PATH}/location_services_patches/$patch_name"
    git clean -q -f
    popd &>> "$DEBUG_LOG"
  else
    die "ERROR: can't find a unifiednlp support patch for the current Android version ($ANDROID_VERSION)"
  fi
}

function set_release_type() {
  out "Setting \"$RELEASE_TYPE\" as release type"
  sed -i "/\$(filter .*\$(${VENDOR^^}_BUILDTYPE)/,+2d" "vendor/$VENDOR/config/common.mk"
}

# Set a custom updater URI if a OTA URL is provided
function set_ota_url() {
  [ -z "$OTA_URL" ] && return

  out "Adding OTA URL overlay (for custom URL $OTA_URL)"
  local updater_url_overlay_dir="vendor/$VENDOR/overlay/microg/packages/apps/Updater/res/values/"
  mkdir -p "$updater_url_overlay_dir"

  if [ -n "$(grep updater_server_url packages/apps/Updater/res/values/strings.xml)" ]; then
    # "New" updater configuration: full URL (with placeholders {device}, {type} and {incr})
    sed "s|{name}|updater_server_url|g; s|{url}|$OTA_URL/v1/{device}/{type}/{incr}|g" "${BUILD_SCRIPTS_PATH}/packages_updater_strings.xml" > "$updater_url_overlay_dir/strings.xml"
  elif [ -n "$(grep conf_update_server_url_def packages/apps/Updater/res/values/strings.xml)" ]; then
    # "Old" updater configuration: just the URL
    sed "s|{name}|conf_update_server_url_def|g; s|{url}|$OTA_URL|g" "${BUILD_SCRIPTS_PATH}/packages_updater_strings.xml" > "$updater_url_overlay_dir/strings.xml"
  else
    die "ERROR: no known Updater URL property found"
  fi
}

# Add custom packages to be installed
function add_custom_packages() {
  [ -z "$CUSTOM_PACKAGES" ] && return

  out "Adding custom packages ($CUSTOM_PACKAGES)"
  sed -i "1s;^;PRODUCT_PACKAGES += $CUSTOM_PACKAGES\n\n;" "vendor/$VENDOR/config/common.mk"
}

function setup_keys() {
  [ "$SIGN_BUILDS" != "true" ] && return

  out "Adding keys path ($KEYS_DIR)"
  # Soong (Android 9+) complains if the signing keys are outside the build path
  ln -sf "$KEYS_DIR" user-keys

  if [ "$ANDROID_VERSION_MAJOR" -lt "10" ]; then
    sed -i "1s;^;PRODUCT_DEFAULT_DEV_CERTIFICATE := user-keys/releasekey\nPRODUCT_OTA_PUBLIC_KEYS := user-keys/releasekey\nPRODUCT_EXTRA_RECOVERY_KEYS := user-keys/releasekey\n\n;" "vendor/$VENDOR/config/common.mk"
  fi

  if [ "$ANDROID_VERSION_MAJOR" -ge "10" ]; then
    sed -i "1s;^;PRODUCT_DEFAULT_DEV_CERTIFICATE := user-keys/releasekey\nPRODUCT_OTA_PUBLIC_KEYS := user-keys/releasekey\n\n;" "vendor/$VENDOR/config/common.mk"
  fi
}

# Prepare the environment
function prepare_build_env() {
  out "Preparing build environment"
  source build/envsetup.sh > /dev/null
}

function mirror_update() {
  out "Updating local mirror"
  CURRENT_DATE=$(date +%Y%m%d)
  if [ "$BUILD_DATE" != "$CURRENT_DATE" ]; then
    # Sync the source code
    BUILD_DATE=$CURRENT_DATE
    mirror_sync
    repo_sync
  fi
}

function mount_overlay() {
  if [ "$BUILD_OVERLAY" == "true" ]; then
    out "Mounting temporary overlay"
    mkdir -p "$TMP_DIR/device" "$TMP_DIR/workdir" "$TMP_DIR/merged"
    sudo mount -t overlay overlay -o lowerdir="$SRC_DIR/$BRANCH_DIR",upperdir="$TMP_DIR/device",workdir="$TMP_DIR/workdir" "$TMP_DIR/merged"
    export SOURCE_DIR="$TMP_DIR/merged"
  else
    export SOURCE_DIR="$SRC_DIR/$BRANCH_DIR"
  fi
}

function make_dirs() {
  local device=$1
  out "Making zip and log subdirectories if missing"
  if [ "$ZIP_SUBDIR" == "true" ]; then
    ZIP_SUB_DIR=$device
    mkdir -p "$ZIP_DIR/$ZIP_SUB_DIR"
  else
    ZIP_SUB_DIR=
  fi
  if [ "$LOGS_SUBDIR" == "true" ]; then
    LOG_SUB_DIR=$device
    mkdir -p "$LOGS_DIR/$LOG_SUB_DIR"
  else
    LOG_SUB_DIR=
  fi
}

function build_device() {
  local branch=$1
  local device=$2
  out "Starting build for $device, $branch branch" | tee -a "$DEBUG_LOG"
  build_successful=false
  if brunch $device &>> "$DEBUG_LOG"; then
    CURRENT_DATE=$(date +%Y%m%d)
    fix_build_date $device
    build_delta $device
    make_checksum $device
    copy_zips $device
    copy_boot
    build_successful=true
  else
    out "Failed build for $device" | tee -a "$DEBUG_LOG"
  fi
}

function fix_build_date() {
  local device=$1
  if [ "$BUILD_DATE" != "$CURRENT_DATE" ]; then
    out "Fixing build date"
    find out/target/product/$device -maxdepth 1 -name "${VENDOR_NAME}-*-$CURRENT_DATE-*.zip*" -type f -exec sh "${BUILD_SCRIPTS_PATH}/fix_build_date.sh" {} $CURRENT_DATE $BUILD_DATE \; &>> "$DEBUG_LOG"
  fi
}

function build_delta() {
  [ "$BUILD_DELTA" != "true" ] && return

  local device=$1
  if [ -d "delta_last/$device/" ]; then
    # If not the first build, create delta files
    out "Generating delta files for $device" | tee -a "$DEBUG_LOG"
    pushd /src/delta &>> "$DEBUG_LOG"
    export HOME_OVERRIDE=/src \
    export BIN_XDELTA=xdelta3 \
    export FILE_MATCH="${VENDOR_NAME}-*.zip"
    export PATH_CURRENT="$SRC_DIR/$BRANCH_DIR/out/target/product/$device"
    export PATH_LAST="$SRC_DIR/$BRANCH_DIR/delta_last/$device"
    export KEY_X509="$KEYS_DIR/releasekey.x509.pem"
    export KEY_PK8="$KEYS_DIR/releasekey.pk8"
    if ./opendelta.sh $device &>> "$DEBUG_LOG"; then
      out "Delta generation for $device completed" | tee -a "$DEBUG_LOG"
    else
      out "Delta generation for $device failed" | tee -a "$DEBUG_LOG"
    fi
    if [ "$DELETE_OLD_DELTAS" -gt "0" ]; then
      /usr/bin/python "${BUILD_SCRIPTS_PATH}/clean_up.py" -n $DELETE_OLD_DELTAS -V $DISTRO_VER -N 1 "$DELTA_DIR/$device" &>> $DEBUG_LOG
    fi
    popd &>> "$DEBUG_LOG"
  else
    # If the first build, copy the current full zip in $SOURCE_DIR/delta_last/$device/
    out "No previous build for $device; using current build as base for the next delta" | tee -a "$DEBUG_LOG"
    mkdir -p delta_last/$device/ &>> "$DEBUG_LOG"
    find out/target/product/$device -maxdepth 1 -name "${VENDOR_NAME}-*.zip" -type f -exec cp {} "$SOURCE_DIR/delta_last/$device/" \; &>> "$DEBUG_LOG"
  fi
}

function make_checksum() {
  local device=$1
  pushd out/target/product/$device &>> "$DEBUG_LOG"
  for build in ${VENDOR_NAME}-*.zip; do
    out "Making sha256sum of $build"
    sha256sum "$build" > "$ZIP_DIR/$ZIP_SUB_DIR/$build.sha256sum"
  done
  popd &>> "$DEBUG_LOG"
}

# Move produced ZIP files to the main OUT directory
function copy_zips() {
  local device=$1
  out "Moving build artifacts for $device to '$ZIP_DIR/$ZIP_SUB_DIR'" | tee -a "$DEBUG_LOG"
  find . -maxdepth 1 -name "${VENDOR_NAME}-*.zip*" -type f -exec mv {} "$ZIP_DIR/$ZIP_SUB_DIR/" \; &>> "$DEBUG_LOG"
}

function copy_boot() {
  if [ "$BOOT_IMG" == "true" ]; then
    out "Copying boot to zip directory"
    find . -maxdepth 1 -name 'boot.img' -type f -exec mv {} "$ZIP_DIR/$ZIP_SUB_DIR/" \; &>> "$DEBUG_LOG"
  fi 
}

# Remove old zips and logs
function cleanup() {
  local device=$1
  if [ "$DELETE_OLD_ZIPS" -gt "0" ]; then
    out "Cleaning up zips"
    if [ "$ZIP_SUBDIR" == "true" ]; then
      /usr/bin/python "${BUILD_SCRIPTS_PATH}/clean_up.py" -n $DELETE_OLD_ZIPS -V $DISTRO_VER -N 1 "$ZIP_DIR/$ZIP_SUB_DIR"
    else
      /usr/bin/python "${BUILD_SCRIPTS_PATH}/clean_up.py" -n $DELETE_OLD_ZIPS -V $DISTRO_VER -N 1 -c $device "$ZIP_DIR"
    fi
  fi
  if [ "$DELETE_OLD_LOGS" -gt "0" ]; then
    out "Cleaning up logs"
    if [ "$LOGS_SUBDIR" == "true" ]; then
      /usr/bin/python "${BUILD_SCRIPTS_PATH}/clean_up.py" -n $DELETE_OLD_LOGS -V $DISTRO_VER -N 1 "$LOGS_DIR/$LOG_SUB_DIR"
    else
      /usr/bin/python "${BUILD_SCRIPTS_PATH}/clean_up.py" -n $DELETE_OLD_LOGS -V $DISTRO_VER -N 1 -c $device "$LOGS_DIR"
    fi
  fi
}

function unmount_overlay() {
  [ "$BUILD_OVERLAY" != "true" ] && return

  out "Unmounting temporary overlay"
  # The Jack server must be stopped manually, as we want to unmount $TMP_DIR/merged
  pushd "$TMP_DIR" &>> "$DEBUG_LOG"
  if [ -f "$TMP_DIR/merged/prebuilts/sdk/tools/jack-admin" ]; then
    "$TMP_DIR/merged/prebuilts/sdk/tools/jack-admin kill-server" &> /dev/null || true
  fi
  lsof | grep "$TMP_DIR/merged" | awk '{ print $2 }' | sort -u | xargs -r kill &> /dev/null

  while [ -n "$(lsof | grep $TMP_DIR/merged)" ]; do
    sleep 1
  done

  sudo umount "$TMP_DIR/merged"
  popd &>> "$DEBUG_LOG"
}

function cleanup_outdir() {
  [ "$CLEAN_AFTER_BUILD" != "true" ] && return

  local device=$1
  out "Cleaning source dir for device $device" | tee -a "$DEBUG_LOG"
  if [ "$BUILD_OVERLAY" == "true" ]; then
    pushd "$TMP_DIR" &>> "$DEBUG_LOG"
    rm -rf device workdir merged
  else
    pushd "$SOURCE_DIR" &>> "$DEBUG_LOG"
    mka clean &>> "$DEBUG_LOG"
  fi
  popd &>> "$DEBUG_LOG"
}

# Create the OpenDelta's builds JSON file
function make_opendelta_builds_json() {
  [ -z "$OPENDELTA_BUILDS_JSON" ] && return

  out "Creating OpenDelta's builds JSON file (ZIP_DIR/$OPENDELTA_BUILDS_JSON)"
  if [ "$ZIP_SUBDIR" != "true" ]; then
    out "WARNING: OpenDelta requires zip builds separated per device! You should set ZIP_SUBDIR to true"
  fi
  /usr/bin/python "${BUILD_SCRIPTS_PATH}/opendelta_builds_json.py" "$ZIP_DIR" -o "$ZIP_DIR/$OPENDELTA_BUILDS_JSON"
}

function cleanup_logs() {
  if [ "$DELETE_OLD_LOGS" -gt "0" ]; then
    out "Cleaning up logs"
    find "$LOGS_DIR" -maxdepth 1 -name repo-*.log | sort | head -n -$DELETE_OLD_LOGS | xargs -r rm
  fi
}

devices=${DEVICE_LIST//,/ }
branches=${BRANCH_NAME//,/ }
REPO_LOG="$LOGS_DIR/repo-$(date +%Y%m%d).log"
export DEBUG_LOG="$REPO_LOG"
BUILD_DATE=$(date +%Y%m%d)

# cd to working directory
cd "$SRC_DIR"

# Generic prepare steps
exec_user_script begin
wipe_outdir
repo_migrate
mirror_init

# Main loop over all branches to be built
for branch in $branches; do
  BRANCH_DIR=$(sed 's/[^[:alnum:]]/_/g' <<< $branch)
  export BRANCH_DIR=${BRANCH_DIR^^}

  cd "$SRC_DIR/$BRANCH_DIR"
  start_branch_build $branch $devices
  repo_reset
  repo_init $branch
  copy_local_manifests
  copy_muppets_manifests $branch
  repo_sync
  get_android_version $branch
  get_vendor_version
  setup_vendor_overlay
  patch_signature_spoofing
  patch_unifiednlp
  set_release_type
  set_ota_url
  add_custom_packages
  setup_keys
  prepare_build_env

  for device in $devices; do
    [ "$device" == "" ] && continue
    DEBUG_LOG="$LOGS_DIR/$device/$VENDOR-$DISTRO_VER-$BUILD_DATE-$RELEASE_TYPE-$device.log"
    if [ "$(user_script_exists before)" == "true" ]; then
      breakfast $device
      exec_user_script before $branch $device
    fi
    mirror_update
    mount_overlay
    cd "$SOURCE_DIR"
    make_dirs $device
    exec_user_script pre-build $branch $device
    build_device $branch $device
    cleanup $device
    exec_user_script post-build $branch $device $build_successful
    out "Finishing build for $device" | tee -a "$DEBUG_LOG"
    unmount_overlay
    cleanup_outdir $device
  done
done

make_opendelta_builds_json
cleanup_logs
exec_user_script end
