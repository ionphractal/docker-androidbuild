#!/bin/bash

# Load environment variables which have not been set already
pushd "${BUILD_SCRIPTS_PATH}" &> /dev/null
SCRIPT_DIR=$(pwd)
source "${BUILD_SCRIPTS_PATH}/load-env.sh"
popd &> /dev/null

# Create all missing directories from env variables
while read dir_variable; do
  # Remove everything in front of the '='
  mkdir -p "${dir_variable#*=}"
done < <(env | grep -E "^[A-Z]+_DIR=")

bash "${BUILD_SCRIPTS_PATH}/init.sh"