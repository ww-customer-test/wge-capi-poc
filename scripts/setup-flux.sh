#!/bin/bash

# Utility for intializing a cluster with flux resources
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@weave.works)

set -euo pipefail
debug=""
export base_dir="$(dirname $(dirname $(realpath ${BASH_SOURCE[0]})))"

function usage()
{
    echo "usage ${0} [--debug]  [--kubeseal] --cluster-name <cluster-name> --git-url <git-url>"
    echo "<cluster-name> is the name of the cluster"
    echo "<git-url> is the url of the github repository to use"
    echo "specify --kubeseal option to deploy kubeseal controller too"
    echo "This script will deploy flux custom resources to a cluster"
}

function args() {
  cluster_name=""
  git_url=""
  debug=""
  kubeseal=""
  arg_list=( "$@" )
  arg_count=${#arg_list[@]}
  arg_index=0
  while (( arg_index < arg_count )); do
    case "${arg_list[${arg_index}]}" in
          "--cluster-name") (( arg_index+=1 ));cluster_name="${arg_list[${arg_index}]}";;
          "--git-url") (( arg_index+=1 ));git_url="${arg_list[${arg_index}]}";;
          "--debug") set -x; debug="--debug";;
          "--kubeseal") kubeseal="yes";;
               "-h") usage; exit;;
           "--help") usage; exit;;
               "-?") usage; exit;;
        *) if [ "${arg_list[${arg_index}]:0:2}" == "--" ];then
               echo "invalid argument: ${arg_list[${arg_index}]}"
               usage; exit 1
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

repo_dir=$(mktemp -d -t ${cluster_name}-XXXXXXXXXX)
git clone ${git_url} ${repo_dir}

#kubectl apply -f ${base_dir}/addons/flux/flux-system/gotk-components.yaml
kubectl wait --for condition=established crd/gitrepositories.source.toolkit.fluxcd.io
kubectl wait --for condition=established crd/kustomizations.kustomize.toolkit.fluxcd.io
setup-kubeseal.sh ${debug} --privatekey-file $CREDS_DIR/sealed-secrets-key --pubkey-file ${repo_dir}/pub-sealed-secrets.pem
if [ -n "$kubeseal" ]; then
  kubectl apply -f ${base_dir}/addons/sealed-secrets
  flux reconcile helmrelease  --namespace kube-system sealed-secrets
  if [ "$(wait-for-deployment.sh ${debug} --wait 120 --namespace kube-system --deployment sealed-secrets)" == "1" ]; then
    echo "1"
    exit 1
  fi
  kubectl apply -f ${base_dir}/addons/sealed-secrets/sealed-secrets-flux.yaml
fi
kubectl wait --for condition=established crd/sealedsecrets.bitnami.com
kubectl apply -f ${repo_dir}/config
#kubectl apply -f ${base_dir}/addons/flux/flux-system/gotk-sync.yaml
kubectl apply -f ${base_dir}/addons/flux/self.yaml

if [ -n "$(kubectl get pod -n flux-system | grep source-controller | awk '{print $1}')" ]; then
  controller="$(kubectl get pod -n flux-system | grep source-controller | awk '{print $1}')"
  kubectl delete pod -n flux-system $controller
fi
