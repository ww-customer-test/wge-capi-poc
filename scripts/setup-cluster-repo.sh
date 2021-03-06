#!/bin/bash

# Utility for intializing a github repository for use as a cluster configuration repository
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@weave.works)

set -euo pipefail
debug=""
export base_dir="$(dirname $(dirname $(realpath ${BASH_SOURCE[0]})))"

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

mkdir -p ${repo_dir}/config
cat > ${repo_dir}/config/cluster-info.yaml << EOF
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-info
  namespace: flux-system
data:
  cluster_repo_url: $(echo -n "${git_url}" | sed s#:#/#)
  cluster_name: ${cluster_name}
  wkp_status: "deployed"
EOF

if [ -z "`git -C ${repo_dir} status | grep 'nothing to commit, working tree clean'`" ] ; then
  git -C ${repo_dir} add config
  git -C ${repo_dir} commit -a -m "add config files"
  git -C ${repo_dir} push
fi

mkdir -p ${repo_dir}/manifests
cp ${base_dir}/resources/dummy.yaml ${repo_dir}/manifests
if [ -z "`git -C ${repo_dir} status | grep 'nothing to commit, working tree clean'`" ] ; then
  git -C ${repo_dir} add manifests/dummy.yaml
  git -C ${repo_dir} commit -a -m "add manifests dummy.yaml"
  git -C ${repo_dir} push
fi

cat > ${repo_dir}/config/cluster-config.yaml << EOF
---
apiVersion: source.toolkit.fluxcd.io/v1beta1
kind: GitRepository
metadata:
  name: cluster-config
  namespace: flux-system
spec:
  interval: 1m0s
  ref:
    branch: main
  secretRef:
    name: cluster-config
  url: ssh://$(echo -n "${git_url}" | sed s#:#/#)
EOF

if [ -z "`git -C ${repo_dir} status | grep 'nothing to commit, working tree clean'`" ] ; then
  git -C ${repo_dir} add config/cluster-config.yaml
  git -C ${repo_dir} commit -a -m "add cluster-config gitrepository custom resource"
  git -C ${repo_dir} push
fi

echo "Generating the sealed secrets private key and certificate..."
openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
    -subj "/" \
    -keyout "${keys_dir}/sealed-secrets-key" \
    -out "${keys_dir}/sealed-secrets-cert.crt"
cp ${keys_dir}/sealed-secrets-cert.crt ${repo_dir}/pub-sealed-secrets.pem
git -C ${repo_dir} add pub-sealed-secrets.pem
git -C ${repo_dir} commit -a -m "add sealed secret public key"
git -C ${repo_dir} push

create-deploy-key.sh ${debug} --file-prefix ${keys_dir}/cluster-keys
deploy-key.sh ${debug} --readonly --pubkey-file ${keys_dir}/cluster-keys.pub --git-url ${git_url}

known_hosts=$(ssh-keyscan github.com 2>/dev/null | base64 --wrap 0)
private_key=$(cat ${keys_dir}/cluster-keys | base64 --wrap=0)
public_key=$(cat ${keys_dir}/cluster-keys.pub | base64 --wrap=0)

kubeseal --format=yaml --cert=${repo_dir}/pub-sealed-secrets.pem > ${repo_dir}/config/cluster-deploy-keys.yaml << EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: cluster-config
  namespace: flux-system
data:
  identity: ${private_key}
  identity.pub: ${public_key}
  known_hosts: ${known_hosts}
type: Opaque
EOF

git -C ${repo_dir} add config/cluster-deploy-keys.yaml
git -C ${repo_dir} commit -a -m "add cluster deploy keys sealed secret"
git -C ${repo_dir} push

create-deploy-key.sh ${debug} --file-prefix ${keys_dir}/addons-keys
deploy-key.sh ${debug} --readonly --pubkey-file ${keys_dir}/addons-keys.pub --git-url $(git -C ${base_dir} remote -v | grep "(fetch)" | awk '{print $2}')

known_hosts=$(ssh-keyscan github.com 2>/dev/null | base64 --wrap 0)
private_key=$(cat ${keys_dir}/addons-keys | base64 --wrap=0)
public_key=$(cat ${keys_dir}/addons-keys.pub | base64 --wrap=0)

kubeseal --format=yaml --cert=${repo_dir}/pub-sealed-secrets.pem > ${repo_dir}/config/addons-deploy-keys.yaml << EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: flux-system
  namespace: flux-system
data:
  identity: ${private_key}
  identity.pub: ${public_key}
  known_hosts: ${known_hosts}
type: Opaque
EOF

git -C ${repo_dir} add config/addons-deploy-keys.yaml
git -C ${repo_dir} commit -a -m "add addons deploy keys sealed secret"
git -C ${repo_dir} push

