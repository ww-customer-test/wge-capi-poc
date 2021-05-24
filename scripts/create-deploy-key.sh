
#!/bin/bash

# Utility for generating ssh keys
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@weave.works)

set -euo pipefail

function usage()
{
    echo "usage ${0} [--debug] [--file-prefix <file-prefix>] [\"<comment>\"]"
    echo "<file-prefix> is the path to the file the private key should be written to"
    echo "the public key will be written to <file-prefix>.pub"
    echo "If no file-prefix is supplied, the file name 'id_rsa' will be used."
    echo "<comment> is an optional comment text for the key pair"
    echo "This script will create an ssh key pair"
}

function args() {
  file_prefix="id_rsa"
  comment=""
  comment_arg=""
  debug=""
  arg_list=( "$@" )
  arg_count=${#arg_list[@]}
  arg_index=0
  while (( arg_index < arg_count )); do
    case "${arg_list[${arg_index}]}" in
          "--file-prefix") (( arg_index+=1 ));file_prefix="${arg_list[${arg_index}]}";;
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
  comment="${arg_list[*]:$arg_index:$(( arg_count - arg_index + 1))}"
  if [ -n "${comment}" ]; then
    comment_arg="-C ${comment}"
  fi
}

args "$@"

rm -f ${file_prefix}
rm -f ${file_prefix}.pub
ssh-keygen -q -t rsa -b 4096 ${comment_arg} -f "${file_prefix}" -N ""

