#!/bin/bash

# Utility for removing sealed secret controller from a cluster
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@weave.works)

set -euo pipefail

function usage()
{
    echo "usage ${0} [--debug] [--kubeconfig <kubeconfig-file>]"
    echo "optional use --kubeconfig option to specify kubeconfig file"
    echo "defaults to KUBECONFIG environmental variable value or $HOME/.kube/config if not set"
    echo "This script will remove the sealed secret controller from a cluster"
}

function args() {
  kubeconfig_path=${KUBECONFIG:-$HOME/.kube/config}
  arg_list=( "$@" )
  arg_count=${#arg_list[@]}
  arg_index=0
  while (( arg_index < arg_count )); do
    case "${arg_list[${arg_index}]}" in
          "--kubeconfig") (( arg_index+=1 ));kubeconfig_path="${arg_list[${arg_index}]}";;
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
}

args "$@"

if [ "$(kubectl -n wkp-flux get deployments.apps 2>/dev/null | grep memcached | awk '{print $1}')" == "memcached" ] ; then
  kubectl -n kube-system delete deployments.apps sealed-secrets-controller
kubectl -n kube-system delete service sealed-secrets-controller
kubectl -n kube-system delete sa sealed-secrets-controller

for secret in $(kubectl -n kube-system get secret | grep sealed | awk '{print $1}'); do kubectl -n kube-system delete secret $secret;done
for secret in $(kubectl -n kube-system get role | grep sealed | awk '{print $1}'); do kubectl -n kube-system delete role $secret;done
for secret in $(kubectl -n kube-system get rolebinding | grep sealed | awk '{print $1}'); do kubectl -n kube-system delete rolebinding $secret;done
for secret in $(kubectl  get clusterrolebinding | grep sealed | awk '{print $1}'); do kubectl delete clusterrolebinding $secret;done

