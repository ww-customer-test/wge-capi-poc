#!/bin/bash

# Utility for setting up tenant clusters
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@weave.works)

set -euo pipefail

function usage()
{
    echo "usage ${0} [--debug] [--kubeconfig <kubeconfig-file>] <path>"
    echo "optional use --kubeconfig option to specify kubeconfig file"
    echo "defaults to KUBECONFIG environmental variable value or $HOME/.kube/config if not set"
    echo "This script will setup flux on a cluster"
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
  path="${arg_list[*]:$arg_index:$(( arg_count - arg_index + 1))}"
  if [ -z "${path:-}" ] ; then
      usage
      exit 1
  fi
}

kubectl -n tenants get secret tenant01-user-kubeconfig -o jsonpath={.data.value} | base64 --decode > ${CREDS_DIR}/tenant01.kubeconfig
export KUBECONFIG=${CREDS_DIR}/tenant01.kubeconfig

deploy-wkp.sh ${debug} git@github.com:ww-customer-test/wkp-tenant01.git

if [ -z "`git status | grep 'nothing to commit, working tree clean'`" ] ; then
    git add -A;git commit -a -m "flux and kubeseal setup for eks tenant01 cluster"; git push
fi

tenant_repo_dir=$(mktemp -d -t ${TENANT_CLUSTER_NAME}-XXXXXXXXXX)

git clone ${TENANT_CLUSTER_REPO_URL} ${tenant_repo_dir}

kubectl apply -f ${tenant_repo_dir}/manifests/cluster-info.yaml
kubectl apply -f addons/flux/flux-system
kubectl apply -f addons/flux/self.yaml

