#!/bin/bash
INFRA_PROVIDERS=aws
BOOTSTRAP_PROVIDERS=kubeadm:v0.3.12,aws-eks
CONTROLPLANE_PROVIDERS=kubeadm:v0.3.12,aws-eks
KEEP_KIND=false
debug=""
base_dir="$dirname($(dirname $(realpath ${BASH_SOURCE[0]})))"

export PATH=$PATH

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
        --mgmt-cluster-repo-url=*)
        MGMT_CLUSTER_REPO_URL="${arg#*=}"
        shift
        ;;
        --mgmt-cluster-name=*)
        MGMT_CLUSTER_NAME="${arg#*=}"
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

if [ -z ${MGMT_CLUSTER_REPO_URL} ]; then
    echo "Management Cluster Repository URL is required, specify using --${MGMT_CLUSTER_NAME}-cluster-repo-url=<git-repo-url>"
    exit 1
fi

if [ -z ${MGMT_CLUSTER_NAME} ]; then
    echo "Management Cluster Name is required, specify using --${MGMT_CLUSTER_NAME}-cluster-name=<cluster name>"
    exit 1
fi

mgmt_repo_dir=$(mktemp -d -t ${MGMT_CLUSTER_NAME}-XXXXXXXXXX)

git clone ${MGMT_CLUSTER_REPO_URL} ${mgmt_repo_dir}

MGMT_CLUSTER_DEF_FILE=${mgmt_repo_dir}/infra/${MGMT_CLUSTER_NAME}/${MGMT_CLUSTER_NAME}.yaml

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

if [ ! -f ${CREDS_DIR}/${MGMT_CLUSTER_NAME}.kubeconfig ]; then
    # No management cluster kubeconfig, creating bootstrap cluster
    echo ""
    echo "Creating bootstrap cluster"
    if [ -z "$(kind get clusters | grep wkp-${MGMT_CLUSTER_NAME}-bootstrap)" ] ; then
        kind create cluster --name=wkp-${MGMT_CLUSTER_NAME}-bootstrap
    fi

    echo "Deploy CAPI and provider"
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

    setup-cluster-repo.sh ${debug} --keys-dir $CREDS_DIR --cluster-name ${MGMT_CLUSTER_NAME} --git-url ${MGMT_CLUSTER_REPO_URL}
    
    git -C ${mgmt_repo_dir} pull
    
    kubectl apply -f ${mgmt_repo_dir}/manifests/cluster-info.yaml
    kubectl apply -k ${base_dir}/addons/flux/flux-system
    kubectl apply -f ${mgmt_repo_dir}/manifests/deploy-key.yaml


    deploy-kubeseal.sh ${debug} --privatekey-file $CREDS_DIR/sealed-secrets-key --pubkey-file ${mgmt_repo_dir}/pub-sealed-secrets.pem

    kubeseal-aws-account.sh ${debug} --key-file ${mgmt_repo_dir}/pub-sealed-secrets.pem --aws-account-name account-one ${mgmt_repo_dir}/eks-accounts/account-one-secret.yaml
    kubeseal-aws-account.sh ${debug} --key-file ${mgmt_repo_dir}/pub-sealed-secrets.pem --aws-account-name account-two ${mgmt_repo_dir}/eks-accounts/account-two-secret.yaml
    git -C ${mgmt_repo_dir} add eks-accounts/account-one-secret.yaml
    git -C ${mgmt_repo_dir} commit -a -m "eks accounts sealed secrets"
    git -C ${mgmt_repo_dir} push

    kubectl apply -f ${mgmt_repo_dir}/manifests/cluster-info.yaml
    kubectl apply -f ${base_dir}/addons/flux/self.yaml
    kubectl apply -f ${mgmt_repo_dir}/clusters/bootstrap/bootstrap.yaml

    kubectl -n flux-system wait --for=condition=ready --timeout 5m kustomization.kustomize.toolkit.fluxcd.io/${MGMT_CLUSTER_NAME}

    echo ""
    echo "Waiting for cluster to be ready"
    kubectl ${namespace_setting} wait --for=condition=ready --timeout 1h cluster/$MGMT_CLUSTER_NAME

    MP=$(cat ${MGMT_CLUSTER_DEF_FILE}| yq e 'select(.kind == "MachinePool")' -)
    if [ "$MP" != "" ]; then
        echo ""
        echo "Waiting for the machine pool to be ready"
        kubectl ${namespace_setting} wait --timeout=30m --for=condition=ready machinepool -l cluster.x-k8s.io/cluster-name=$MGMT_CLUSTER_NAME
    fi

    echo ""
    echo "Setup CAPI in management cluster: $MGMT_CLUSTER_NAME"
    kubectl ${namespace_setting} get secret $MGMT_CLUSTER_NAME-kubeconfig -o jsonpath={.data.value} | base64 --decode > ~/${MGMT_CLUSTER_NAME}.kubeconfig
    if [ -z "$(kubectl --kubeconfig ~/${MGMT_CLUSTER_NAME}.kubeconfig get ns capi-system 2>/dev/null)" ] ; then
        clusterctl init  --kubeconfig ~/${MGMT_CLUSTER_NAME}.kubeconfig -i $INFRA_PROVIDERS -c $CONTROLPLANE_PROVIDERS -b $BOOTSTRAP_PROVIDERS --core cluster-api:v0.3.12
    fi
    kubectl wait --kubeconfig ~/${MGMT_CLUSTER_NAME}.kubeconfig --for=condition=ready --timeout=2m pod -l cluster.x-k8s.io/provider=control-plane-eks -n capi-webhook-system
    kubectl wait --kubeconfig ~/${MGMT_CLUSTER_NAME}.kubeconfig --for=condition=ready --timeout=2m pod -l cluster.x-k8s.io/provider=infrastructure-aws -n capi-webhook-system
    kubectl wait --kubeconfig ~/${MGMT_CLUSTER_NAME}.kubeconfig --for=condition=ready --timeout=2m pod -l cluster.x-k8s.io/provider=cluster-api -n capi-webhook-system
    kubectl wait --kubeconfig ~/${MGMT_CLUSTER_NAME}.kubeconfig --for=condition=ready --timeout=2m pod -l cluster.x-k8s.io/provider=bootstrap-kubeadm -n capi-webhook-system
    kubectl wait --kubeconfig ~/${MGMT_CLUSTER_NAME}.kubeconfig --for=condition=ready --timeout=2m pod -l cluster.x-k8s.io/provider=control-plane-kubeadm -n capi-webhook-system

    echo ""
    echo "Pivot into the new management cluster"
    # NOTE: we get the secret again as the token is short lived
    kubectl ${namespace_setting} get secret $MGMT_CLUSTER_NAME-kubeconfig -o jsonpath={.data.value} | base64 --decode > ~/${MGMT_CLUSTER_NAME}.kubeconfig
    clusterctl move --to-kubeconfig ~/${MGMT_CLUSTER_NAME}.kubeconfig

    echo ""
    echo "Get user kubeconfig"
    kubectl ${namespace_setting} get secret $MGMT_CLUSTER_NAME-user-kubeconfig -o jsonpath={.data.value} | base64 --decode > ${CREDS_DIR}/${MGMT_CLUSTER_NAME}.kubeconfig

    if [ "$KEEP_KIND" == "false" ]; then
        echo ""
        echo "Delete bootstrap cluster"
        kind delete cluster --name=wkp-${MGMT_CLUSTER_NAME}-bootstrap
    fi
fi
export KUBECONFIG=${CREDS_DIR}/${MGMT_CLUSTER_NAME}.kubeconfig

deploy-wkp.sh ${debug} --git-url git@github.com:ww-customer-test/wkp-mgmt01.git

kubectl apply -f ${mgmt_repo_dir}/manifests/cluster-info.yaml
kubectl apply -f ${mgmt_repo_dir}/manifests/manifests.yaml
kubectl apply -f ${base_dir}/addons/flux/flux-system
kubectl apply -f ${mgmt_repo_dir}/clusters/bootstrap/bootstrap.yaml

kubectl apply -f ${mgmt_repo_dir}/clusters/${MGMT_CLUSTER_NAME}/tenants.yaml

export CREDS_DIR=$HOME/tenant01
source $CREDS_DIR/aws-account-one.sh
tenants.sh tenant01 git@github.com:ww-customer-test/tenant01-cluster.git

export CREDS_DIR=$HOME/tenant02
source $CREDS_DIR/aws-account-two.sh
tenants.sh tenant02 git@github.com:ww-customer-test/tenant02-cluster.git

