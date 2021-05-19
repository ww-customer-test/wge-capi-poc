#!/bin/bash
INFRA_PROVIDERS=aws
BOOTSTRAP_PROVIDERS=kubeadm:v0.3.12,aws-eks
CONTROLPLANE_PROVIDERS=kubeadm:v0.3.12,aws-eks
KEEP_KIND=false
debug=""

set -euo pipefail

for arg in "$@"
do
    case $arg in
        -i=*|--infrastructure=*)
        INFRA_PROVIDERS="${arg#*=}"
        shift
        ;;
        -b=*|--bootstrap=*)
        BOOTSTRAP_PROVIDERS="${arg#*=}"
        shift
        ;;
        -c=*|--controlplane=*)
        CONTROLPLANE_PROVIDERS="${arg#*=}"
        shift
        ;;
        --aws-access-key-id=*)
        AWS_ACCESS_KEY_ID="${arg#*=}"
        shift
        ;;
        --aws-secret-access-key=*)
        AWS_SECRET_ACCESS_KEY="${arg#*=}"
        shift
        ;;
        --mgmt-cluster-def-file=*)
        MGMT_CLUSTER_DEF_FILE="${arg#*=}"
        shift
        ;;
        --region=*)
        AWS_REGION="${arg#*=}"
        shift
        ;;
        --creds-dir=*)
        CREDS_DIR="${arg#*=}"
        shift
        ;;
        --github-user=*)
        GITHUB_USER="${arg#*=}"
        shift
        ;;
        --github-org=*)
        GITHUB_ORG="${arg#*=}"
        shift
        ;;
        --github-repo=*)
        GITHUB_REPO="${arg#*=}"
        shift
        ;;
        --github-token=*)
        GITHUB_TOKEN="${arg#*=}"
        shift
        ;;
        --keep-kind=*)
        KEEP_KIND="${arg#*=}"
        shift
        ;;
        --debug)
        set -x
        debug="--debug"
        shift
        ;;
        *)
        shift
        ;;
    esac
done

if [ "${INFRA_PROVIDERS:-}" == "" ]; then
    echo "You must supply infra providers using -i=provider1,provider2"
    exit 10
fi

export GITHUB_USER=${GITHUB_USER:-$(git config -f ~/.gitconfig --get user.name)}
export GITHUB_ORG=${GITHUB_ORG:-$(git config -f ~/.gitconfig --get user.name)}
export GITHUB_REPO=${GITHUB_REPO:-$(basename $(git rev-parse --show-toplevel))}

if [ "${GITHUB_TOKEN:-}" == "" ]; then
    echo "You must supply a github user --github-token"
    exit 10
fi

if [[ "${INFRA_PROVIDERS:-}" == *"aws"* ]]; then
    if [ "${AWS_ACCESS_KEY_ID:-}" == "" ]; then
        echo "When using AWS provider you need to supply an AWS access key id using --aws-access-key-id=ABCDEF"
        exit 11
    fi
    export AWS_ACCESS_KEY_ID

    if [ "${AWS_SECRET_ACCESS_KEY:-}" == "" ]; then
        echo "When using AWS provider you need to supply an AWS access key secret using ---aws-secret-access-key=mysecret"
        exit 11
    fi
    export AWS_SECRET_ACCESS_KEY

    if [ "${AWS_REGION:-}" == "" ]; then
        AWS_REGION=eu-west-1
        echo "aws-region option not supplied, defaulting to ${AWS_REGION}"
    fi
    export AWS_REGION
fi

export CREDS_DIR=${CREDS_DIR:-$HOME}

MGMT_CLUSTER_DEF_FILE=${MGMT_CLUSTER_DEF_FILE:-./cluster-specs/bootstrap/eks-mgmt/eks-mgmt.yaml}

cat ${MGMT_CLUSTER_DEF_FILE}

# TODO: query for the Cluster instead of assuming its the first document
CLUSTER_NAME=$(cat ${MGMT_CLUSTER_DEF_FILE} | yq e 'select(documentIndex == 1) | .metadata.name' -)
echo "Found cluster $CLUSTER_NAME in downloaded definition"

CLUSTER_NAMESPACE=$(cat ${MGMT_CLUSTER_DEF_FILE} | yq e 'select(documentIndex == 1) | .metadata.namespace' -)
if [ "${CLUSTER_NAMESPACE}" != "null" ] ; then
    echo "cluster namespace: $CLUSTER_NAMESPACE"
    namespace_setting="-n ${CLUSTER_NAMESPACE}"
else
    namespace_setting=""
fi

if [[ "${INFRA_PROVIDERS:-}" == *"aws"* ]]; then
    echo ""
    echo "Encoding AWS credentials"
    export AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID 
    export AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY
    export AWS_B64ENCODED_CREDENTIALS=$(clusterawsadm bootstrap credentials encode-as-profile)
fi

export GITHUB_TOKEN

echo ""
echo "Cluster API Initialize"
export EXP_EKS=true
export EXP_EKS_IAM=false
export EXP_MACHINE_POOL=true
export EXP_CLUSTER_RESOURCE_SET=true


if [ -z "`git status | grep 'nothing to commit, working tree clean'`" ] ; then
    git add -A;git commit -a -m "commit changes before bootstrap"; git push
fi


    # Create bootstrap cluster
    echo ""
    echo "Creating bootstrap cluster"
    if [ -z "$(kind get clusters | grep wkp-mgmt-bootstrap)" ] ; then
        kind create cluster --name=wkp-mgmt-bootstrap
    fi

    if [ -z "$(kubectl  get ns capi-system)" ] ; then
        clusterctl init -i $INFRA_PROVIDERS -c $CONTROLPLANE_PROVIDERS -b $BOOTSTRAP_PROVIDERS --core cluster-api:v0.3.12
    fi

    echo ""
    echo "Waiting for CAPI webhooks"
    kubectl wait --for=condition=ready --timeout=2m pod -l cluster.x-k8s.io/provider=control-plane-eks -n capi-webhook-system
    kubectl wait --for=condition=ready --timeout=2m pod -l cluster.x-k8s.io/provider=infrastructure-aws -n capi-webhook-system
    kubectl wait --for=condition=ready --timeout=2m pod -l cluster.x-k8s.io/provider=cluster-api -n capi-webhook-system
    kubectl wait --for=condition=ready --timeout=2m pod -l cluster.x-k8s.io/provider=bootstrap-kubeadm -n capi-webhook-system
    kubectl wait --for=condition=ready --timeout=2m pod -l cluster.x-k8s.io/provider=control-plane-kubeadm -n capi-webhook-system

    kubectl apply -f cluster-specs/bootstrap/eks-mgmt/eks-mgmt.yaml

    echo ""
    echo "Waiting for cluster to be ready"
    kubectl ${namespace_setting} wait --for=condition=ready --timeout 1h cluster/$CLUSTER_NAME

    MP=$(cat ${MGMT_CLUSTER_DEF_FILE}| yq e 'select(.kind == "MachinePool")' -)
    if [ "$MP" != "" ]; then
        echo ""
        echo "Waiting for the machine pool to be ready"
        kubectl ${namespace_setting} wait --timeout=30m --for=condition=ready machinepool -l cluster.x-k8s.io/cluster-name=$CLUSTER_NAME
    fi

    kubectl delete -f cluster-specs/bootstrap/eks-mgmt/eks-mgmt.yaml
    exit
    if [ "$MP" != "" ]; then
        echo ""
        echo "Waiting for the machine pool to be deleted"
        while [ "$(kubectl ${namespace_setting} get machinepool -l cluster.x-k8s.io/cluster-name=$CLUSTER_NAME 2>/dev/null | awk '{print $1}' | grep "^flux$")" != "flux" ] ; do
        if [ "$timeout" ==  "0" ]; then
            echo "flux not deployed"
            exit 1
        fi
        sleep 1
        timeout=$((timeout-1))
        done
    fi

    echo ""
    echo "Waiting for cluster to be deleted"
    kubectl ${namespace_setting} wait --for=condition=ready --timeout 1h cluster/$CLUSTER_NAME

    if [ "$KEEP_KIND" == "false" ]; then
        echo ""
        echo "Delete bootstrap cluster"
        kind delete cluster --name=wkp-mgmt-bootstrap
    fi
fi

