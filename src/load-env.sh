#!/bin/bash

function load_env() {
  local env_file="${BUILD_SCRIPTS_PATH}/build-env"
  if [ ! -f "$env_file" ]; then
    echo "ERROR: Env variable file can't be loaded. '$env_file' not accessible."
    exit 1
  fi

  while read line; do
    # continue if line does not start with a-z or A-Z
    grep -s -E "^[a-zA-Z]" <<<"$line" &>/dev/null || continue
    local key=$(awk -F'=' '{print $1}' <<<"$line")
    local value=${line#*=}
    # remove all leading and following (single/double) quotes from value
    value=$(sed -e "s#^['\"]##" -e "s#['\"]\$##" <<<"$value")
    # interpolate variables
    value=$(eval "echo $value")
    if [ -z "${!key}" ]; then
      echo "Loading '$key' default value: $value"
      export $key="${!key:-$value}"
    fi
  done < <(cat "$env_file")
}

load_env