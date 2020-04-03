#!/bin/bash
# Execute this script in the build context so that env variables are set respectively
env | grep "_DIR"

function git_base_url() {
  local url=$1
  local base=$(dirname "$url")
  base=$(sed -re 's#^https?://[^/]+/##' <<<"$base")
  base=$(sed -re 's#[^a-zA-Z0-9]#_#g' <<<"$base")
  echo $base
}

pushd "$SRC_DIR/$BRANCH_DIR" | tee -a "$DEBUG_LOG"
mkdir -p prebuilts/prebuiltapks
while read git_url git_branch app_list; do
  [ -z "$git_url" ] && continue
  [ -z "$git_branch" ] && git_branch="master"
  git_name=$(git_base_url "$git_url")
  mkdir -p "$SRC_DIR/prebuiltapks"
  pushd "$SRC_DIR/prebuiltapks" | tee -a "$DEBUG_LOG"
  if [ ! -d "$git_name" ]; then
    git clone --single-branch -b "$git_branch" "$git_url" "$git_name" | tee -a "$DEBUG_LOG"
  else
    pushd "$git_name" | tee -a "$DEBUG_LOG"
    git fetch --all | tee -a "$DEBUG_LOG"
    git checkout "$git_branch" | tee -a "$DEBUG_LOG"
    popd | tee -a "$DEBUG_LOG"
  fi
  popd | tee -a "$DEBUG_LOG"
  for app in $app_list; do
    if grep "$app" <<<"$CUSTOM_PACKAGES" &> /dev/null; then
      [ -d "prebuilts/prebuiltapks/$app" ] && rm -R "prebuilts/prebuiltapks/$app"
      rsync -av --delete "$SRC_DIR/prebuiltapks/$git_name/$app" prebuilts/prebuiltapks/ | tee -a "$DEBUG_LOG"
    fi
  done
done < "$BUILD_SCRIPTS_PATH/prebuiltapks"
popd | tee -a "$DEBUG_LOG"