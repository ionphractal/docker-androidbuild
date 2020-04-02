#!/bin/bash

# Load environment variables which have not been set already
pushd $(dirname $0)
SCRIPT_DIR=$(pwd)
bash "${BUILD_SCRIPTS_PATH}/load-env.sh"
popd

# Create all missing directories from env variables
while read dir_variable; do
  # Remove everything in front of the '='
  mkdir -p "${dir_variable#*=}"
done < <(env | grep -E "^[A-Z]+_DIR=")

bash "${BUILD_SCRIPTS_PATH}/init.sh"