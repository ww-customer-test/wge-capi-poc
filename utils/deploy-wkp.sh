#!/bin/bash

# Utility for deploying wkp components on an existing cluster
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@weave.works)

set -euo pipefail
debug=""

function usage()
{
    echo "usage ${0} [--debug] [--kubeconfig <kubeconfig-file>] <git-url>"
    echo "optional use --kubeconfig option to specify kubeconfig file"
    echo "defaults to KUBECONFIG environmental variable value or $HOME/.kube/config if not set"
    echo "This script will setup wkp on a cluster, use <git-url> to specify the directory the repository to use"
}

function args() {
  kubeconfig_path=${KUBECONFIG:-$HOME/.kube/config}
  arg_list=( "$@" )
  arg_count=${#arg_list[@]}
  arg_index=0
  while (( arg_index < arg_count )); do
    case "${arg_list[${arg_index}]}" in
          "--kubeconfig") (( arg_index+=1 ));kubeconfig_path="${arg_list[${arg_index}]}";;
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
if [ "$?" == "0" ] ; then
    echo "wkp installed on cluster"
    exit 0
fi
set -e

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

sed s#GIT_URL#${git_url}# ~/config.yaml > setup/config.yaml
export WKP_DEBUG=true
wk setup run -v
popd