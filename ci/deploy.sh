#!/bin/bash
set -o errexit
set -o nounset
cd $(dirname $0)

secrets="${PIPELINE_SECRETS:-../../concourse-secrets.yml}"
pipeline_name=$(basename $(git rev-parse --show-toplevel))

function parse_yaml {
  local prefix=${2:-}
  local s='[[:space:]]*' w='[a-zA-Z0-9_]*' fs=$(echo @|tr @ '\034')
  sed -ne "s|^\($s\):|\1|" \
      -e "s|^\($s\)\($w\)$s:$s[\"']\(.*\)[\"']$s\$|\1$fs\2$fs\3|p" \
      -e "s|^\($s\)\($w\)$s:$s\(.*\)$s\$|\1$fs\2$fs\3|p"  $1 |
  awk -F$fs '{
    indent = length($1)/2;
    vname[indent] = $2;
    for (i in vname) {if (i > indent) {delete vname[i]}}
    if (length($3) > 0) {
      vn=""; for (i=0; i<indent; i++) {vn=(vn)(vname[i])("_")}
      printf("%s%s%s=\"%s\"\n", "'$prefix'",vn, $2, $3);
    }
  }'
}

if [ ! -f $secrets ]; then
  echo "ERROR: secrets.yml not found"
  exit 1
fi
source <(parse_yaml "$secrets")

fly -t "$concourse_target" login --concourse-url "$concourse_url" -u "$concourse_username" -p "$concourse_password" --team-name main
[ "${1:-}" == "login" ] && exit 0

echo -e "\nUpdating '$pipeline_name' from file 'pipeline.yml'"
fly -t "$concourse_target" set-pipeline -p "$pipeline_name" -c "pipeline.yml" --load-vars-from $secrets </dev/tty
