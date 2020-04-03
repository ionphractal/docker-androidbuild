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

pushd "$SRC_DIR/$BRANCH_DIR"
mkdir -p prebuilts/prebuiltapks
while read git_url git_branch app_list; do
  [ -z "$git_url" ] && continue
  [ -z "$git_branch" ] && git_branch="master"
  git_name=$(git_base_url "$git_url")
  mkdir -p "$TMP_DIR/prebuiltapks"
  pushd "$TMP_DIR/prebuiltapks"
  git clone --single-branch -b "$git_branch" "$git_url" "$git_name"
  popd
  for app in $app_list; do
    rsync -av --delete "$TMP_DIR/prebuiltapks/$git_name/$app" prebuilts/prebuiltapks/
  done
done < "$BUILD_SCRIPTS_PATH/prebuiltapks"
popd