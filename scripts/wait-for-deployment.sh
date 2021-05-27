#!/bin/bash

# Utility for checking if a deployment is deployed
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@weave.works)

set -euo pipefail

function usage()
{
    echo "usage ${0} [--debug] [--kubeconfig <kubeconfig-file>] [--wait <seconds>] [--namespace <namespace>] --deployment <deployment name>"
    echo "optional use --kubeconfig option to specify kubeconfig file"
    echo "defaults to KUBECONFIG environmental variable value or $HOME/.kube/config if not set"
    echo "by default the script waits 30 seconds for components to be deployed"
    echo "use the --wait option to specify an alternative wait period if needed"
    echo "use the --namespace option to specify the namespace to search for deployment, defaults to 'default'"
    echo "This script will wait for a deployment to be deployed"
}

function args() {
  kubeconfig_path=${KUBECONFIG:-$HOME/.kube/config}
  namesapce="default"
  wait=30
  arg_list=( "$@" )
  arg_count=${#arg_list[@]}
  arg_index=0
  while (( arg_index < arg_count )); do
    case "${arg_list[${arg_index}]}" in
          "--kubeconfig") (( arg_index+=1 ));kubeconfig_path="${arg_list[${arg_index}]}";;
          "--namespace") (( arg_index+=1 ));namespace="${arg_list[${arg_index}]}";;
          "--deployment") (( arg_index+=1 ));deployment="${arg_list[${arg_index}]}";;
          "--debug") set -x;;
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
  if [ -z "$deployment" ]; then
    usage
    exit 1
  fi
}

args "$@"

timeout=$wait
while [ "$(kubectl -n $namespace get deployments.apps 2>/dev/null | awk '{print $1}' | grep "^${deployment}$")" != "$deployment" ] ; do
  if [ $timeout -lt  0 ]; then
    echo "1"
    exit
  fi
  sleep 1
  timeout=$((timeout-1))
done

if [ "$(kubectl wait --for=condition=Available --timeout=${wait}s -n $namespace deployments.apps $deployment | grep "condition met" | awk '{$1=""; print $0}' | sed 's/^[ \t]*//;s/[ \t]*$//')" == "condition met" ]; then
  echo "0"
  exit
fi

echo "1"