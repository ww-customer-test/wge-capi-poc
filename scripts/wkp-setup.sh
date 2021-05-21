#!/bin/bash

# Utility for doing or redoing wkp setup
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@weave.works)

function usage()
{
    echo "usage ${0} [--debug]"
    echo "This script will setup wkp in directory"
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

wk setup install << EOF > /tmp/wkp-setup.txt

EOF

if [ "$?" == "0" ] ; then
    echo "wkp setup install executed"
    exit 0
fi

grep "Found existing config.yaml and/or gitops-params.yaml file" /tmp/wkp-setup.txt
if [ "$?" == "0" ] ; then
    echo "Already setup"
    rm -rf /tmp/wkp-bin
    mkdir -p /tmp/wkp-bin
    pushd /tmp/wkp-bin
    wk setup install
    popd
    cp -rf /tmp/wkp-bin/bin .
fi
