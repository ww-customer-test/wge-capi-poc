#!/bin/bash

# Utility for setting up tenant clusters
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@weave.works)

set -euo pipefail

function usage()
{
    echo "usage ${0} [--debug] [--kubeconfig <kubeconfig-file>] --tenant-name <tenant-name> --git-url <url of tenant cluster github repository"
    echo "optional use --kubeconfig option to specify kubeconfig file"
    echo "defaults to KUBECONFIG environmental variable value or $HOME/.kube/config if not set"
    echo "<cluster-name> is the name of the cluster"
    echo "<git-url> is the url of the github repository to use"
    echo "This script will setup tenant cluster"
}

function args() {
  kubeconfig_path=${KUBECONFIG:-$HOME/.kube/config}
  debug=""
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
  path="${arg_list[*]:$arg_index:$(( arg_count - arg_index + 1))}"
  if [ -z "${path:-}" ] ; then
      usage
      exit 1
  fi
}

echo ""
echo "Waiting for tenant clusters to be ready"
kubectl wait --for=condition=ready --timeout 1h -n tenants cluster/${tenant_name}

kubectl -n tenants get secret ${tenant_name}-user-kubeconfig -o jsonpath={.data.value} | base64 --decode > ${CREDS_DIR}/${tenant_name}.kubeconfig
export KUBECONFIG=${CREDS_DIR}/${tenant_name}.kubeconfig

tenant_repo_dir=$(mktemp -d -t ${TENANT_CLUSTER_NAME}-XXXXXXXXXX)

git clone ${TENANT_CLUSTER_REPO_URL} ${tenant_repo_dir}

setup-cluster-repo.sh ${debug} --keys-dir $CREDS_DIR --cluster-name $tenant_name} --git-url ${tenant_repo_dir}

deploy-wkp.sh ${debug} --git-url git@github.com:ww-customer-test/wkp-${tenant_name}.git

kubectl apply -f ${tenant_repo_dir}/manifests/cluster-info.yaml
kubectl apply -f ${tenant_repo_dir}/manifests/manifests.yaml
kubectl apply -f addons/flux/flux-system
