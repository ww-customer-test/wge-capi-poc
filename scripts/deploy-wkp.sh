#!/bin/bash

# Utility for deploying wkp components on an existing cluster
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@weave.works)

set -euo pipefail
debug=""

function usage()
{
    echo "usage ${0} [--debug] <git-url>"
    echo "This script will setup wkp on a cluster, use <git-url> to specify the directory the repository to use"
}

function args() {
  arg_list=( "$@" )
  arg_count=${#arg_list[@]}
  arg_index=0
  while (( arg_index < arg_count )); do
    case "${arg_list[${arg_index}]}" in
          "--debug") set -x; debug="--debug";;
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
  git_url="${arg_list[*]:$arg_index:$(( arg_count - arg_index + 1))}"
  if [ -z "${git_url:-}" ] ; then
      usage
      exit 1
  fi
  dir_name="$(echo "${git_url}" | cut -f2 -d/ | cut -f1 -d.)"
  if [ -d "${dir_name}" ] ; then
    if [ -f "${dir_name}" ] ; then
      echo "${dir_name} is a file not a directory"
      exit 1
    fi
  else
    mkdir -p ${dir_name} 
  fi
}

args "$@"

set +e
wkp-installed.sh --wait 1
if [[ "$?" == "0" ]] ; then
    echo "wkp installed on cluster"
    exit 0
fi
set -e

script_dir=$(dirname ${BASH_SOURCE[0]})
pushd ${dir_name}

if [ -z "$(git remote | grep origin)" ] ; then
  git remote add origin ${git_URL}
fi
git branch --set-upstream-to=origin/master master
git pull

wkp-setup.sh ${debug}

if [ -e cluster/platform/gitops-secrets.yaml ] ; then
  echo "gitops secret yaml already present, reseting"
  rm -rf * .flux.yaml .gitignore
  git reset --hard v2.5.0
  git push -f
  remove-wkp-kubeseal.sh ${debug}
  remove-wkp-flux1.sh ${debug}
  wkp-setup.sh ${debug}
fi

sed s#GIT_URL#${git_url}# ${script_dir}/../addons/wkp/config.yaml | \
  sed s/CLUSTER_NAME/${cluster_name}/ | \
  sed s#CREDS_DIR#${CREDS_DIR}# > setup/config.yaml

cp ${script_dir}/../addons/wkp/setup.sh setup
export WKP_DEBUG=true
export TRACE_SETUP=y
export GITURL_ORG="$(echo "${git_url}" | cut -f2 -d: | cut -f1 -d/)"
export GITURL_REPO="${dir_name}"
wk setup run -v
popd