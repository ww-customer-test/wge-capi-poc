#!/bin/bash

# Utility for intializing a github repository for use as a cluster configuration repository
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@weave.works)

set -euo pipefail
debug=""

function usage()
{
    echo "usage ${0} [--debug] [--keys-dir <keys-directory>] --cluster-name <cluster-name> --git-url <git-url>"
    echo "<cluster-name> is the name of the cluster"
    echo "<git-url> is the url of the github repository to use"
    echo "This script will setup a github repository for use as a cluster configuration repository"
}

function args() {
  cluster_name=""
  keys_dir="${HOME}"
  git_url=""
  debug=""
  arg_list=( "$@" )
  arg_count=${#arg_list[@]}
  arg_index=0
  while (( arg_index < arg_count )); do
    case "${arg_list[${arg_index}]}" in
          "--cluster-name") (( arg_index+=1 ));cluster_name="${arg_list[${arg_index}]}";;
          "--git-url") (( arg_index+=1 ));git_url="${arg_list[${arg_index}]}";;
          "--keys-dir") (( arg_index+=1 ));keys_dir="${arg_list[${arg_index}]}";;
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
  if [ -z "${git_url:-}" ] ; then
      usage
      exit 1
  fi
}

args "$@"

repo_dir=$(mktemp -d -t ${cluster_name}-XXXXXXXXXX)
git clone ${git_url} ${repo_dir}

create-deploy-key.sh ${debug} --file-prefix ${keys_dir}/flux-keys
deploy-key.sh ${debug} --readonly --pubkey-file ${keys_dir}/flux-keys.pub --git-url ${git_url}

mkdir -p ${repo_dir}/manifests
cat > ${repo_dir}/manifests/cluster-info.yaml << EOF
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-info
  namespace: kube-system
data:
  cluster_repo_url: ${git_url}
  cluster_name: ${cluster_name}
EOF

private_key=$(cat ${keys_dir}/flux-keys | base64 --wrap=0)
cat > ${repo_dir}/manifests/deploy-key.yaml << EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: cluster-config
  namespace: flux-system
data:
  identity: ${private_key}
EOF

if git  -C ${repo_dir} diff-index --quiet HEAD manifests ; then
  git -C ${repo_dir} add manifests
  git -C ${repo_dir} commit -a -m "add cluster config and deploy key to manifest files"
  git -C ${repo_dir} push
fi

if [ ! -f "${repo_dir}/pub-sealed-secrets.pem" ] ; then
    echo "Generating the sealed secrets private key and certificate..."
    openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
        -subj "/" \
        -keyout "${keys_dir}/sealed-secrets-key" \
        -out "${keys_dir}/sealed-secrets-cert.crt"
    cp ${keys_dir}/sealed-secrets-cert.crt ${repo_dir}/pub-sealed-secrets.pem
    git -C ${repo_dir} add pub-sealed-secrets.pem
    git -C ${repo_dir} commit -a -m "add sealed secret public key"
    git -C ${repo_dir} push
fi
