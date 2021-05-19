#!/bin/bash

# Utility for removing wkp flux1 from a cluster
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

if [ "$(kubectl -n wkp-gitops-bootstrap get jobs.batch 2>/dev/null | awk '{print $1}' | grep "^gitops-bootstrap$")" == "gitops-bootstrap" ] ; then
  kubectl -n wkp-gitops-bootstrap delete jobs.batch gitops-bootstrap
fi

if [ "$(kubectl -n wkp-flux get deployments.apps 2>/dev/null | grep memcached | awk '{print $1}')" == "memcached" ] ; then
  kubectl -n wkp-flux delete deployments.apps memcached
fi
if [ "$(kubectl -n wkp-flux get deployments.apps 2>/dev/null | awk '{print $1}' | grep "^flux$")" == "flux" ] ; then
  kubectl -n wkp-flux delete deployments.apps flux
fi
if [ "$(kubectl -n wkp-flux get deployments.apps 2>/dev/null | awk '{print $1}' | grep "^flux-helm-operator$")" == "flux-helm-operator" ] ; then
  kubectl -n wkp-flux delete deployments.apps flux-helm-operator
fi
if [ "$(kubectl -n wkp-flux get services 2>/dev/null | grep memcached | awk '{print $1}')" == "memcached" ] ; then
  kubectl -n wkp-flux delete service memcached
fi
if [ "$(kubectl -n wkp-flux get sa 2>/dev/null | grep flux | awk '{print $1}')" == "flux" ] ; then
  kubectl -n wkp-flux delete sa flux
fi

for secret in $(kubectl -n wkp-flux get secret | grep flux | awk '{print $1}'); do kubectl -n wkp-flux delete secret $secret;done
for secret in $(kubectl  get clusterrolebinding | grep flux | awk '{print $1}'); do kubectl delete clusterrolebinding $secret;done
for secret in $(kubectl  get clusterrole | grep flux | awk '{print $1}'); do kubectl delete clusterrole $secret;done
if [ "$(kubectl get ns 2>/dev/null | awk '{print $1}' | grep "^wkp-flux$")" == "wkp-flux" ] ; then
  kubectl delete ns wkp-flux
fi
