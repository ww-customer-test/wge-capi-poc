#!/bin/bash

# Utility for installing required software
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@weave.works)

set -euo pipefail

function usage()
{
    echo "usage ${0} [--debug]"
    echo "This script will install require software on linux client"
}

function args() {

  arg_list=( "$@" )
  arg_count=${#arg_list[@]}
  arg_index=0
  while (( arg_index < arg_count )); do
    case "${arg_list[${arg_index}]}" in
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

export CLUSTER_API_VERSION=0.3.16
export CAPA_VERSION=0.6.5
export YQ_VERSION=v4.6.1

curl -s -Lo ./kind https://kind.sigs.k8s.io/dl/v0.10.0/kind-linux-amd64 && \
chmod +x ./kind && \
sudo mv ./kind /usr/local/bin/

curl -s -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && \
chmod +x ./kubectl && \
sudo mv ./kubectl /usr/local/bin

curl -s -L https://github.com/kubernetes-sigs/cluster-api/releases/download/v${CLUSTER_API_VERSION}/clusterctl-linux-amd64 -o clusterctl && \
chmod +x ./clusterctl && \
sudo mv ./clusterctl /usr/local/bin

curl -s -L  https://github.com/kubernetes-sigs/cluster-api-provider-aws/releases/download/v${CAPA_VERSION}/clusterawsadm-linux-amd64 -o clusterawsadm && \
chmod +x ./clusterawsadm && \
sudo mv ./clusterawsadm /usr/local/bin

brew install flux

sudo curl -s -L  https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64 -o /usr/local/bin/yq && \
sudo chmod +x /usr/local/bin/yq

brew install kubeseal
