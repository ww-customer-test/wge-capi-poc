#!/bin/bash

# Utility for deploying wkp components on an existing cluster
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@weave.works)

set -euo pipefail

function usage()
{
    echo "usage ${0} [--debug] --cluster-name <cluster-name> --git-url <git-url>"
    echo "<cluster-name> is the name of the cluster"
    echo "<git-url> is the url of the github repository to use for WKP install"
    echo "This script will setup wkp on a cluster, use <git-url> to specify the directory the repository to use"
}

function args() {
  git_url=""
  debug=""
  arg_list=( "$@" )
  arg_count=${#arg_list[@]}
  arg_index=0
  while (( arg_index < arg_count )); do
    case "${arg_list[${arg_index}]}" in
          "--cluster-name") (( arg_index+=1 ));cluster_name="${arg_list[${arg_index}]}";;
          "--git-url") (( arg_index+=1 ));git_url="${arg_list[${arg_index}]}";;
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
  dir_name="$(echo "${git_url}" | cut -f2 -d/ | cut -f1 -d.)"
  if [ -z "${cluster_name:-}" ] ; then
      usage
      exit 1
  fi
}

args "$@"

set +e
wkp-installed.sh --wait 1
if [[ "$?" == "0" ]] ; then
    echo "wkp installed on cluster"
    exit 0
fi
set -e

script_dir=$(dirname ${BASH_SOURCE[0]})
repo_dir=$(mktemp -d -t wkp-${cluster_name}-XXXXXXXXXX)
git clone ${git_url} ${repo_dir}
pushd ${repo_dir}

if [ -z "$(git remote | grep origin)" ] ; then
  git remote add origin ${git_URL}
fi
git branch --set-upstream-to=origin/master master
git pull

wkp-setup.sh ${debug}

if [ -e cluster/platform/gitops-secrets.yaml ] ; then
  echo "gitops secret yaml already present, reseting"
  rm -rf * .flux.yaml .gitignore
  git reset --hard $(git log --pretty=oneline --pretty=format:"%H %ae %s" | grep "support@weave.works Initial commit" | awk '{print $1}')
  git push -f
  remove-wkp-kubeseal.sh ${debug}
  remove-wkp-flux1.sh ${debug}
  wkp-setup.sh ${debug}
fi

sed s#GIT_URL#${git_url}# ${script_dir}/../addons/wkp/config.yaml | \
  sed s/CLUSTER_NAME/${cluster_name}/ | \
  sed s#CREDS_DIR#${CREDS_DIR}# > setup/config.yaml

cp $CREDS_DIR/sealed-secrets-cert.crt setup
cp $CREDS_DIR/sealed-secrets-key setup

cp ${script_dir}/../addons/wkp/setup.sh setup
export WKP_DEBUG=true
export TRACE_SETUP=y
export GITURL_ORG="$(echo "${git_url}" | cut -f2 -d: | cut -f1 -d/)"
export GITURL_REPO="${dir_name}"
wk setup run -v
popd