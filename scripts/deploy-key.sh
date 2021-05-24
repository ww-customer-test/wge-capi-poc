#!/bin/bash

# Utility for deploying keys to github repo
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@weave.works)

set -euo pipefail

function usage()
{
    echo "usage ${0} [--debug] [--read-only] --pubkey-file <key-file> --git-url <git-url>"
    echo "<key-file> is the path to the file containing the public key"
    echo "<git-url> is the url of the github repository to add deploy key to"
    echo "This script will add deploy key to a github repo"
}

function args() {
  key_file=""
  git_url=""
  read_only="false"
  debug=""
  arg_list=( "$@" )
  arg_count=${#arg_list[@]}
  arg_index=0
  while (( arg_index < arg_count )); do
    case "${arg_list[${arg_index}]}" in
          "--pubkey-file") (( arg_index+=1 ));key_file="${arg_list[${arg_index}]}";;
          "--git-url") (( arg_index+=1 ));git_url="${arg_list[${arg_index}]}";;
          "--debug") set -x; debug="--debug";;
          "--read-only") read_only="true";;
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
  if [ -z "${key_file:-}" ] ; then
      usage
      exit 1
  fi
  if [ -z "${git_url:-}" ] ; then
      usage
      exit 1
  fi
}

args "$@"

export GITURL_ORG="$(echo "${git_url}" | cut -f2 -d: | cut -f1 -d/)"
export GITURL_REPO="$(echo "${git_url}" | cut -f2 -d/ | cut -f1 -d.)"

curl -i -H"Authorization: token $GITHUB_TOKEN" --data @- https://api.github.com/repos/$GITURL_ORG/$GITURL_REPO/keys << EOF
{
    "title" : "$GITURL_REPO $(date)",
    "key" : "$(cat $key_file)",
    "read_only" : ${read_only}
}
EOF
