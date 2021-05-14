#!/bin/bash

# Utility for setting up kubeseal
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@weave.works)

set -euo pipefail

function usage()
{
    echo "usage ${0} [--debug] --key-file <key-file> --aws-account-name <aws-account-name> <sealed-secret-file>"
    echo "the --key option specifies the name of the kubeseal public key file"
    echo "the --aws-account-name option specifies the name of the AWS account."
    echo "The account name is used in secret namespace specification and to source credentials from file <aws-account-name>.sh"
    echo "The <aws-account-name>.sh file will be sources from the directory path specified by the CREDS_DIR environmental variable"
    echo "If the CREDS_DIR environmental variable is not set the HOME environmental variable will be used"
    echo "path is the path within the repository to store the public key file"
    echo "This script will setup kubeseal on a cluster"
}

function args() {
  key_file=""
  aws_account=""

  arg_list=( "$@" )
  arg_count=${#arg_list[@]}
  arg_index=0
  while (( arg_index < arg_count )); do
    case "${arg_list[${arg_index}]}" in
          "--key-file") (( arg_index+=1 ));key_file="${arg_list[${arg_index}]}";;
          "--aws-account-name") (( arg_index+=1 ));aws_account="${arg_list[${arg_index}]}";;
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
  sealed_secret_file="${arg_list[*]:$arg_index:$(( arg_count - arg_index + 1))}"
  if [ -z "${sealed_secret_file:-}" ] ; then
      usage; exit 1
  fi
  if [ -z "${key_file:-}" ] ; then
      usage; exit 1
  fi
  if [ -z "${aws_account:-}" ] ; then
      usage; exit 1
  fi
  if [ ! -e ${CREDS_DIR:-$HOME}/${aws_account}.sh ] ; then
      echo "file: ${CREDS_DIR:-$HOME}${aws_account}.sh not found" ; exit 1
  fi
}

args "$@"

source ${CREDS_DIR:-$HOME}/${aws_account}.sh

kubectl -n ${aws_account} create secret generic account-creds \
    --from-literal=AccessKeyID=${AWS_ACCESS_KEY_ID} \
    --from-literal=SecretAccessKey=${AWS_SECRET_ACCESS_KEY} \
    --dry-run=client \
    -o yaml > /tmp/aws-auth.yaml

kubeseal --format=yaml --cert=./${key_file} < /tmp/aws-auth.yaml > ${sealed_secret_file}

rm /tmp/aws-auth.yaml

