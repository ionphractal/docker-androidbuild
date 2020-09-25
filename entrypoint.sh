#!/bin/bash

# Load environment variables which have not been set already
source "${BUILD_SCRIPTS_PATH}/load-env.sh"

# Make sure all files are owned by the build user
sudo chown ${BUILD_USER_ID}:${BUILD_USER_GID} /srv/*

# Create all missing directories from env variables
while read dir_variable; do
  # Remove everything in front of the '='
  mkdir -p "${dir_variable#*=}"
done < <(env | grep -E "^[A-Z]+_DIR=")

# Adjust build scripts path depending on what the user wants to build and run the flavor start script
export BUILD_FLAVOR_SCRIPTS_PATH="${BUILD_SCRIPTS_PATH}/flavors/${BUILD_FLAVOR:-microg}"

bash "${BUILD_FLAVOR_SCRIPTS_PATH}/${BUILD_FLAVOR_START_SCRIPT:-init.sh}"
