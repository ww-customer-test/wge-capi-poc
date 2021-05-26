#!/bin/bash

# Utility for checking a cluster is deployed and wkp-components are installed.
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@weave.works)

set -euo pipefail

export base_dir="$(dirname $(dirname $(realpath ${BASH_SOURCE[0]})))"

function usage()
{
    echo "usage ${0} [--debug] [--kubeconfig <kubeconfig-file>] --cluster-name <cluster-name> --git-url <url of cluster github repository>"
    echo "optional use --kubeconfig option to specify kubeconfig file"
    echo "defaults to KUBECONFIG environmental variable value or $HOME/.kube/config if not set"
    echo "<cluster-name> is the name of the cluster"
    echo "<git-url> is the url of the github repository to use"
    echo "This script will verify the cluster is deployed with wkp-components"
}

function args() {
  kubeconfig_path=${KUBECONFIG:-$HOME/.kube/config}
  debug=""
  cluster_name=""
  git_url=""
  arg_list=( "$@" )
  arg_count=${#arg_list[@]}
  arg_index=0
  while (( arg_index < arg_count )); do
    case "${arg_list[${arg_index}]}" in
          "--kubeconfig") (( arg_index+=1 ));kubeconfig_path="${arg_list[${arg_index}]}";;
          "--cluster-name") (( arg_index+=1 ));cluster_name="${arg_list[${arg_index}]}";;
          "--git-url") (( arg_index+=1 ));git_url="${arg_list[${arg_index}]}";;
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
  if [ -z "${git_url:-}" ] ; then
      usage
      exit 1
  fi
  if [ -z "${cluster_name:-}" ] ; then
      usage
      exit 1
  fi
}

args "$@"

source $CREDS_DIR/account.sh
export KUBECONFIG=${kubeconfig_path}

status="$(kubectl -n flux-system get cm cluster-info -o json | jq -r '.data.status')"
echo "$status"
