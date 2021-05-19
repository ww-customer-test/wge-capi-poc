#!/bin/bash

# Utility for deploying keys to github repo
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@weave.works)

set -euo pipefail

function usage()
{
    echo "usage ${0} [--debug] <keyfile>"
    echo "<keyfile> is the path to the file containing the public key"
    echo "This script will add deploy key to a github repo"
}

function args() {
  arg_list=( "$@" )
  arg_count=${#arg_list[@]}
  arg_index=0
  while (( arg_index < arg_count )); do
    case "${arg_list[${arg_index}]}" in
          "--debug") set -x;;
               "-h") usage; exit;;
           "--help") usage; exit;;
               "-?") usage; exit;;
        *) if [ "${arg_list[${arg_index}]:0:2}" == "--" ];then
               echo "invalid argument: ${arg_list[${arg_index}]}"
               usage; exit
           fi;
           break;;
    esac
    (( arg_index+=1 ))
  done
  keyfile="${arg_list[*]:$arg_index:$(( arg_count - arg_index + 1))}"
  if [ -z "${keyfile:-}" ] ; then
      usage
      exit 1
  fi
}

args "$@"


curl -i -H"Authorization: token $GITHUB_TOKEN" --data @- https://api.github.com/repos/$GITURL_ORG/$GITURL_REPO/keys << EOF
{
    "title" : "$GITURL_REPO $(date)",
    "key" : "$(cat $keyfile)",
    "read_only" : false
}
EOF
