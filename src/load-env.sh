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
  export $key="${!key:-$value}"
done < <(cat ../.env)
