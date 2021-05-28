#!/bin/bash

# Utility for checking wkp is installed
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@weave.works)

set -euo pipefail

function usage()
{
    echo "usage ${0} [--debug] [--kubeconfig <kubeconfig-file>] [--wait <seconds>]"
    echo "optional use --kubeconfig option to specify kubeconfig file"
    echo "defaults to KUBECONFIG environmental variable value or $HOME/.kube/config if not set"
    echo "by default the script waits 30 seconds for components to be deployed"
    echo "use the --wait option to specify an alternative wait period if needed"
    echo "This script will check if wkp is installed on a cluster"
}

function args() {
  kubeconfig_path=${KUBECONFIG:-$HOME/.kube/config}
  debug=""
  wait=30
  arg_list=( "$@" )
  arg_count=${#arg_list[@]}
  arg_index=0
  while (( arg_index < arg_count )); do
    case "${arg_list[${arg_index}]}" in
          "--kubeconfig") (( arg_index+=1 ));kubeconfig_path="${arg_list[${arg_index}]}";;
          "--debug") set -x; debug="--debug";;
          "--wait") (( arg_index+=1 ));wait="${arg_list[${arg_index}]}";;
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
}

args "$@"

if [ "$(wait-for-deployment.sh ${debug} --wait $wait --namespace wkp-flux --deployment flux)" == "1" ]; then
  echo "1"
  exit
fi

echo "0"
