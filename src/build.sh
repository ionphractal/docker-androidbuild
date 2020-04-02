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
  echo ">> [$(date)] "${1+"$@"}
}

function die() {
  out "${1+"$@"}"
  exit 1
}

function exec_user_script() {
  local script="${BUILD_SCRIPTS_PATH}/userscripts/${1}.sh"
  shift
  if [ -f "$script" ]; then
    out "Executing '$script'"
    $script ${1+"@"}
  fi
}

function user_script_exists() {
  local script="${BUILD_SCRIPTS_PATH}/userscripts/${1}.sh"
  if [ -f "$script" ]; then
    return true
  else
    return false
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

  local branch_dir=$(repo info -o | sed -ne 's/Manifest branch: refs\/heads\///p' | sed 's/[^[:alnum:]]/_/g')
  branch_dir=${branch_dir^^}
  out "WARNING: old source dir detected, moving source from \"\$SRC_DIR\" to \"\$SRC_DIR/$branch_dir\""
  if [ -d "$branch_dir" ] && [ -z "$(ls -A "$branch_dir")" ]; then
    out "ERROR: $branch_dir already exists and is not empty; aborting"
  fi
  mkdir -p "$branch_dir"
  find . -maxdepth 1 ! -name "$branch_dir" ! -path . -exec mv {} "$branch_dir" \;
}

function mirror_sync() {
  [ "$LOCAL_MIRROR" != "true" ] && return

  out "Syncing mirror repository" | tee -a "$repo_log"
  pushd "$MIRROR_DIR"
  repo sync --force-sync --no-clone-bundle &>> "$repo_log"
  popd
}

function mirror_init() {
  [ "$LOCAL_MIRROR" != "true" ] && return

  pushd "$MIRROR_DIR"

  if [ ! -d .repo ]; then
    out "Initializing mirror repository" | tee -a "$repo_log"
    yes | repo init -u https://github.com/LineageOS/mirror --mirror --no-clone-bundle -p linux &>> "$repo_log"
  fi

  # Copy local manifests to the appropriate folder in order take them into consideration
  out "Copying '$LMANIFEST_DIR/*.xml' to '.repo/local_manifests/'"
  mkdir -p .repo/local_manifests
  rsync -a --delete --include '*.xml' --exclude '*' "$LMANIFEST_DIR/" .repo/local_manifests/

  rm -f .repo/local_manifests/proprietary.xml
  if [ "$INCLUDE_PROPRIETARY" == "true" ]; then
    wget -q -O .repo/local_manifests/proprietary.xml "https://raw.githubusercontent.com/TheMuppets/manifests/mirror/default.xml"
    /usr/bin/python "${BUILD_SCRIPTS_PATH}/build_manifest.py" \
      --remote "https://gitlab.com" \
      --remotename "gitlab_https" \
      "https://gitlab.com/the-muppets/manifest/raw/mirror/default.xml" .repo/local_manifests/proprietary_gitlab.xml
  fi

  mirror_sync
  popd
}

function start_branch_build() {
  mkdir -p "$SRC_DIR/$branch_dir"
  out "Branch :  $branch"
  out "Devices:  $devices"
}

# Remove previous changes of vendor/cm, vendor/lineage and frameworks/base (if they exist)
function repo_reset() {
  for path in "vendor/cm" "vendor/lineage" "frameworks/base"; do
    if [ -d "$path" ]; then
      pushd "$path"
      git reset -q --hard
      git clean -q -fd
      popd
    fi
  done
}

function repo_init() {
  out "(Re)initializing branch repository" | tee -a "$repo_log"
  if [ "$LOCAL_MIRROR" == "true" ]; then
    yes | repo init -u https://github.com/LineageOS/android.git --reference "$MIRROR_DIR" -b "$branch" &>> "$repo_log"
  else
    yes | repo init -u https://github.com/LineageOS/android.git -b "$branch" &>> "$repo_log"
  fi
}

# Copy local manifests to the appropriate folder in order take them into consideration
function copy_local_manifests() {
  out "Copying '$LMANIFEST_DIR/*.xml' to '.repo/local_manifests/'"
  mkdir -p .repo/local_manifests
  rsync -a --delete --include '*.xml' --exclude '*' "$LMANIFEST_DIR/" .repo/local_manifests/
}

function copy_muppets_manifests() {
  rm -f .repo/local_manifests/proprietary.xml
  [ "$INCLUDE_PROPRIETARY" != "true" ] && return

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
  wget -q -O .repo/local_manifests/proprietary.xml "https://raw.githubusercontent.com/TheMuppets/manifests/$themuppets_branch/muppets.xml"
  /usr/bin/python "${BUILD_SCRIPTS_PATH}/build_manifest.py" \
    --remote "https://gitlab.com" \
    --remotename "gitlab_https" \
    "https://gitlab.com/the-muppets/manifest/raw/$themuppets_branch/muppets.xml" .repo/local_manifests/proprietary_gitlab.xml
}

function repo_sync() {
  out "Syncing branch repository" | tee -a "$repo_log"
  pushd "$SRC_DIR/$branch_dir"
  repo sync -c --force-sync &>> "$repo_log"
  popd
}

function get_android_version() {
  platform_code=$(sed -n -e 's/^\s*DEFAULT_PLATFORM_VERSION := //p' build/core/version_defaults.mk)
  android_version=$(sed -n -e 's/^\s*PLATFORM_VERSION\.'$platform_code' := //p' build/core/version_defaults.mk)
  if [ -z $android_version ]; then
    die "Can't detect the android version"
  fi
  android_version_major=$(cut -d '.' -f 1 <<< $android_version)

  if [ "$android_version_major" -lt "7" ]; then
    die "ERROR: $branch requires a JDK version too old (< 8); aborting"
  fi
}

function get_vendor_version() {
  if [ "$android_version_major" -ge "8" ]; then
    vendor="lineage"
  else
    vendor="cm"
  fi

  if [ ! -d "vendor/$vendor" ]; then
    die "ERROR: Missing \"vendor/$vendor\", aborting"
  fi

  los_ver_major=$(sed -n -e 's/^\s*PRODUCT_VERSION_MAJOR = //p' "vendor/$vendor/config/common.mk")
  los_ver_minor=$(sed -n -e 's/^\s*PRODUCT_VERSION_MINOR = //p' "vendor/$vendor/config/common.mk")
  los_ver="$los_ver_major.$los_ver_minor"
}

# Set up our overlay
function setup_vendor_overlay() {
  mkdir -p "vendor/$vendor/overlay/microg/"
  sed -i "1s;^;PRODUCT_PACKAGE_OVERLAYS := vendor/$vendor/overlay/microg\n;" "vendor/$vendor/config/common.mk"
}

# If needed, apply the microG's signature spoofing patch
function patch_signature_spoofing() {
  if [ "$SIGNATURE_SPOOFING" != "yes" ] || [ "$SIGNATURE_SPOOFING" != "restricted" ]; then
    return
  fi

  # Determine which patch should be applied to the current Android source tree
  patch_name=""
  case $android_version in
    4.4*  )    patch_name="android_frameworks_base-KK-LP.patch" ;;
    5.*   )    patch_name="android_frameworks_base-KK-LP.patch" ;;
    6.*   )    patch_name="android_frameworks_base-M.patch" ;;
    7.*   )    patch_name="android_frameworks_base-N.patch" ;;
    8.*   )    patch_name="android_frameworks_base-O.patch" ;;
    9*|9.*)    patch_name="android_frameworks_base-P.patch" ;; #not sure why 9 not 9.0 but here's a fix that will work until android 90
    10*   )    patch_name="android_frameworks_base-Q.patch" ;;
  esac

  if ! [ -z $patch_name ]; then
    pushd frameworks/base
    if [ "$SIGNATURE_SPOOFING" == "yes" ]; then
      out "Applying the standard signature spoofing patch ($patch_name) to frameworks/base"
      out "WARNING: the standard signature spoofing patch introduces a security threat"
      patch --quiet -p1 -i "${BUILD_SCRIPTS_PATH}/signature_spoofing_patches/$patch_name"
    else
      out "Applying the restricted signature spoofing patch (based on $patch_name) to frameworks/base"
      sed 's/android:protectionLevel="dangerous"/android:protectionLevel="signature|privileged"/' "${BUILD_SCRIPTS_PATH}/signature_spoofing_patches/$patch_name" | patch --quiet -p1
    fi
    git clean -q -f
    popd

    # Override device-specific settings for the location providers
    mkdir -p "vendor/$vendor/overlay/microg/frameworks/base/core/res/res/values/"
    cp "${BUILD_SCRIPTS_PATH}/signature_spoofing_patches/frameworks_base_config.xml" "vendor/$vendor/overlay/microg/frameworks/base/core/res/res/values/config.xml"
  else
    die "ERROR: can't find a suitable signature spoofing patch for the current Android version ($android_version)"
  fi
}

function patch_unifiednlp() {
  [ "$SUPPORT_UNIFIEDNLP" != "true" ] && return

  # Determine which patch should be applied to the current Android source tree
  patch_name=""
  case $android_version in
    10*  )    patch_name="android_frameworks_base-Q.patch" ;;
  esac

  if ! [ -z $patch_name ]; then
    pushd frameworks/base
      out "Applying location services patch"
      patch --quiet -p1 -i "${BUILD_SCRIPTS_PATH}/location_services_patches/$patch_name"
    git clean -q -f
    popd
  else
    die "ERROR: can't find a unifiednlp support patch for the current Android version ($android_version)"
  fi
}

function set_release_type() {
  out "Setting \"$RELEASE_TYPE\" as release type"
  sed -i "/\$(filter .*\$(${vendor^^}_BUILDTYPE)/,+2d" "vendor/$vendor/config/common.mk"
}

# Set a custom updater URI if a OTA URL is provided
function set_ota_url() {
  [ -z "$OTA_URL" ] && return

  out "Adding OTA URL overlay (for custom URL $OTA_URL)"
  updater_url_overlay_dir="vendor/$vendor/overlay/microg/packages/apps/Updater/res/values/"
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
  sed -i "1s;^;PRODUCT_PACKAGES += $CUSTOM_PACKAGES\n\n;" "vendor/$vendor/config/common.mk"
}

function setup_keys() {
  [ "$SIGN_BUILDS" != "true" ] && return

  out "Adding keys path ($KEYS_DIR)"
  # Soong (Android 9+) complains if the signing keys are outside the build path
  ln -sf "$KEYS_DIR" user-keys

  if [ "$android_version_major" -lt "10" ]; then
    sed -i "1s;^;PRODUCT_DEFAULT_DEV_CERTIFICATE := user-keys/releasekey\nPRODUCT_OTA_PUBLIC_KEYS := user-keys/releasekey\nPRODUCT_EXTRA_RECOVERY_KEYS := user-keys/releasekey\n\n;" "vendor/$vendor/config/common.mk"
  fi

  if [ "$android_version_major" -ge "10" ]; then
    sed -i "1s;^;PRODUCT_DEFAULT_DEV_CERTIFICATE := user-keys/releasekey\nPRODUCT_OTA_PUBLIC_KEYS := user-keys/releasekey\n\n;" "vendor/$vendor/config/common.mk"
  fi
}

# Prepare the environment
function prepare_build_env() {
  out "Preparing build environment"
  source build/envsetup.sh > /dev/null
}

function mirror_update() {
  currentdate=$(date +%Y%m%d)
  if [ "$builddate" != "$currentdate" ]; then
    # Sync the source code
    builddate=$currentdate
    mirror_sync
    repo_sync
  fi
}

function mount_overlay() {
  if [ "$BUILD_OVERLAY" == "true" ]; then
    mkdir -p "$TMP_DIR/device" "$TMP_DIR/workdir" "$TMP_DIR/merged"
    sudo mount -t overlay overlay -o lowerdir="$SRC_DIR/$branch_dir",upperdir="$TMP_DIR/device",workdir="$TMP_DIR/workdir" "$TMP_DIR/merged"
    source_dir="$TMP_DIR/merged"
  else
    source_dir="$SRC_DIR/$branch_dir"
  fi
}

function make_dirs() {
  if [ "$ZIP_SUBDIR" == "true" ]; then
    zipsubdir=$codename
    mkdir -p "$ZIP_DIR/$zipsubdir"
  else
    zipsubdir=
  fi
  if [ "$LOGS_SUBDIR" == "true" ]; then
    logsubdir=$codename
    mkdir -p "$LOGS_DIR/$logsubdir"
  else
    logsubdir=
  fi

  DEBUG_LOG="$LOGS_DIR/$logsubdir/lineage-$los_ver-$builddate-$RELEASE_TYPE-$codename.log"
}

function build_device() {
  local codename=$1
  out "Starting build for $codename, $branch branch" | tee -a "$DEBUG_LOG"
  build_successful=false
  if brunch $codename &>> "$DEBUG_LOG"; then
    currentdate=$(date +%Y%m%d)
    fix_build_date
    build_delta
    make_checksum
    copy_zips
    copy_boot
    build_successful=true
  else
    out "Failed build for $codename" | tee -a "$DEBUG_LOG"
  fi
}

function fix_build_date() {
  if [ "$builddate" != "$currentdate" ]; then
    find out/target/product/$codename -maxdepth 1 -name "lineage-*-$currentdate-*.zip*" -type f -exec sh "${BUILD_SCRIPTS_PATH}/fix_build_date.sh" {} $currentdate $builddate \; &>> "$DEBUG_LOG"
  fi
}

function build_delta() {
  [ "$BUILD_DELTA" != "true" ] && return

  if [ -d "delta_last/$codename/" ]; then
    # If not the first build, create delta files
    out "Generating delta files for $codename" | tee -a "$DEBUG_LOG"
    pushd /src/delta
    export HOME_OVERRIDE=/src \
    export BIN_XDELTA=xdelta3 \
    export FILE_MATCH=lineage-*.zip
    export PATH_CURRENT=$SRC_DIR/$branch_dir/out/target/product/$codename
    export PATH_LAST=$SRC_DIR/$branch_dir/delta_last/$codename
    export KEY_X509=$KEYS_DIR/releasekey.x509.pem
    export KEY_PK8=$KEYS_DIR/releasekey.pk8
    if ./opendelta.sh $codename &>> "$DEBUG_LOG"; then
      out "Delta generation for $codename completed" | tee -a "$DEBUG_LOG"
    else
      out "Delta generation for $codename failed" | tee -a "$DEBUG_LOG"
    fi
    if [ "$DELETE_OLD_DELTAS" -gt "0" ]; then
      /usr/bin/python ${BUILD_SCRIPTS_PATH}/clean_up.py -n $DELETE_OLD_DELTAS -V $los_ver -N 1 "$DELTA_DIR/$codename" &>> $DEBUG_LOG
    fi
    popd
  else
    # If the first build, copy the current full zip in $source_dir/delta_last/$codename/
    out "No previous build for $codename; using current build as base for the next delta" | tee -a "$DEBUG_LOG"
    mkdir -p delta_last/$codename/ &>> "$DEBUG_LOG"
    find out/target/product/$codename -maxdepth 1 -name 'lineage-*.zip' -type f -exec cp {} "$source_dir/delta_last/$codename/" \; &>> "$DEBUG_LOG"
  fi
}

function make_checksum() {
  pushd out/target/product/$codename
  for build in lineage-*.zip; do
    sha256sum "$build" > "$ZIP_DIR/$zipsubdir/$build.sha256sum"
  done
  popd
}

# Move produced ZIP files to the main OUT directory
function copy_zips() {
  out "Moving build artifacts for $codename to '$ZIP_DIR/$zipsubdir'" | tee -a "$DEBUG_LOG"
  find . -maxdepth 1 -name 'lineage-*.zip*' -type f -exec mv {} "$ZIP_DIR/$zipsubdir/" \; &>> "$DEBUG_LOG"
}

function copy_boot() {
  if [ "$BOOT_IMG" == "true" ]; then
    find . -maxdepth 1 -name 'boot.img' -type f -exec mv {} "$ZIP_DIR/$zipsubdir/" \; &>> "$DEBUG_LOG"
  fi 
}

# Remove old zips and logs
function cleanup() {
  if [ "$DELETE_OLD_ZIPS" -gt "0" ]; then
    if [ "$ZIP_SUBDIR" == "true" ]; then
      /usr/bin/python "${BUILD_SCRIPTS_PATH}/clean_up.py" -n $DELETE_OLD_ZIPS -V $los_ver -N 1 "$ZIP_DIR/$zipsubdir"
    else
      /usr/bin/python "${BUILD_SCRIPTS_PATH}/clean_up.py" -n $DELETE_OLD_ZIPS -V $los_ver -N 1 -c $codename "$ZIP_DIR"
    fi
  fi
  if [ "$DELETE_OLD_LOGS" -gt "0" ]; then
    if [ "$LOGS_SUBDIR" == "true" ]; then
      /usr/bin/python "${BUILD_SCRIPTS_PATH}/clean_up.py" -n $DELETE_OLD_LOGS -V $los_ver -N 1 "$LOGS_DIR/$logsubdir"
    else
      /usr/bin/python "${BUILD_SCRIPTS_PATH}/clean_up.py" -n $DELETE_OLD_LOGS -V $los_ver -N 1 -c $codename "$LOGS_DIR"
    fi
  fi
}

function unmount_overlay() {
  [ "$BUILD_OVERLAY" != "true" ] && return

  # The Jack server must be stopped manually, as we want to unmount $TMP_DIR/merged
  pushd "$TMP_DIR"
  if [ -f "$TMP_DIR/merged/prebuilts/sdk/tools/jack-admin" ]; then
    "$TMP_DIR/merged/prebuilts/sdk/tools/jack-admin kill-server" &> /dev/null || true
  fi
  lsof | grep "$TMP_DIR/merged" | awk '{ print $2 }' | sort -u | xargs -r kill &> /dev/null

  while [ -n "$(lsof | grep $TMP_DIR/merged)" ]; do
    sleep 1
  done

  sudo umount "$TMP_DIR/merged"
  popd
}

function cleanup_outdir() {
  [ "$CLEAN_AFTER_BUILD" != "true" ] && return

  out "Cleaning source dir for device $codename" | tee -a "$DEBUG_LOG"
  if [ "$BUILD_OVERLAY" == "true" ]; then
    pushd "$TMP_DIR"
    rm -rf device workdir merged
  else
    pushd "$source_dir"
    mka clean &>> "$DEBUG_LOG"
  fi
  popd
}

# Create the OpenDelta's builds JSON file
function make_opendelta_builds_json() {
  [ -z "$OPENDELTA_BUILDS_JSON" ] && return

  out "Creating OpenDelta's builds JSON file (ZIP_DIR/$OPENDELTA_BUILDS_JSON)"
  if [ "$ZIP_SUBDIR" !== "true" ]; then
    out "WARNING: OpenDelta requires zip builds separated per device! You should set ZIP_SUBDIR to true"
  fi
  /usr/bin/python "${BUILD_SCRIPTS_PATH}/opendelta_builds_json.py" "$ZIP_DIR" -o "$ZIP_DIR/$OPENDELTA_BUILDS_JSON"
}

function cleanup_logs() {
  if [ "$DELETE_OLD_LOGS" -gt "0" ]; then
    find "$LOGS_DIR" -maxdepth 1 -name repo-*.log | sort | head -n -$DELETE_OLD_LOGS | xargs -r rm
  fi
}

devices=${DEVICE_LIST//,/ }
branches=${BRANCH_NAME//,/ }
repo_log="$LOGS_DIR/repo-$(date +%Y%m%d).log"
builddate=$(date +%Y%m%d)

# cd to working directory
cd "$SRC_DIR"

exec_user_script begin

wipe_outdir

repo_migrate

mirror_init

for branch in $branches; do
  branch_dir=$(sed 's/[^[:alnum:]]/_/g' <<< $branch)
  branch_dir=${branch_dir^^}

  cd "$SRC_DIR/$branch_dir"
  start_branch_build
  repo_reset
  repo_init
  copy_local_manifests
  copy_muppets_manifests
  repo_sync
  get_android_version
  get_vendor_version
  setup_vendor_overlay
  patch_signature_spoofing
  patch_unifiednlp
  set_release_type
  set_ota_url
  add_custom_pachages
  setup_keys
  prepare_build_env

  for device in $devices; do
    [ "$device" == "" ] && continue
    if [ "$(user_script_exists before)" == "true" ]; then
      breakfast $device
      exec_user_script before $device
    fi
    mirror_update
    mount_overlay
    cd "$source_dir"
    make_dirs
    exec_user_script pre-build $device
    build_device $device $build_successful
    cleanup
    exec_user_script post-build $device $build_successful
    out "Finishing build for $device" | tee -a "$DEBUG_LOG"
    unmount_overlay
    cleanup_outdir
  done
done

make_opendelta_builds_json
cleanup_logs
exec_user_script end