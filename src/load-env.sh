#!/bin/bash

if [ ! -f ".env" ]; then
  echo "No '.env'"
  exit 1
fi

while read line; do
  # continue if line does not start with a-z or A-Z
  grep -s -E "^[a-zA-Z]" <<<"$line" &>/dev/null || continue
  key=$(awk -F'=' '{print $1}' <<<"$line")
  value=${line#*=}
  # remove all leading and following (single/double) quotes from value
  value=$(sed -e "s#^['\"]##" -e "s#['\"]\$##" <<<"$value")
  if [ -z "${!key}" ]; then
    echo "Loading '$key' default value: $value"
    export $key="${!key:-$value}"
  fi
done < <(cat .env)
