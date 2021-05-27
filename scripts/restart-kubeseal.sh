#!/bin/bash

# Utility for restarting kubeseal controller
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@weave.works)

set -euo pipefail

function usage()
{
    echo "usage ${0} [--debug] "
    echo "This script will restart kubeseal controller"
}

function args() {
  debug=""
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
}

args "$@"
if [ -n "$(kubectl get pod -n kube-system | grep sealed-secrets | awk '{print $1}')" ]; then
  controller="$(kubectl get pod -n kube-system | grep sealed-secrets | awk '{print $1}')"
  kubectl delete pod -n kube-system $controller
fi
