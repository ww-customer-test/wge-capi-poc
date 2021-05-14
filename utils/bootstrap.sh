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

if [ ! -f ${CREDS_DIR}/mgmt.kubeconfig ]; then
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

    ./utils/deploy-flux.sh ${debug} cluster-specs/bootstrap/flux
    ./utils/deploy-kubeseal.sh ${debug} clusters/bootstrap
    ./utils/kubeseal-aws-account.sh ${debug} --key-file clusters/bootstrap/pub-sealed-secrets.pem --aws-account-name account-one cluster-specs/bootstrap/eks-accounts/account-one-secret.yaml
   git add -A;git commit -a -m "kubeseal setup for bootstrap cluster"; git push

    kubectl apply -f clusters/bootstrap/self.yaml

    kubectl -n flux-system wait --for=condition=ready --timeout 5m kustomization.kustomize.toolkit.fluxcd.io/eks-mgmt

    echo ""
    echo "Waiting for cluster to be ready"
    kubectl ${namespace_setting} wait --for=condition=ready --timeout 1h cluster/$CLUSTER_NAME

    MP=$(cat ${MGMT_CLUSTER_DEF_FILE}| yq e 'select(.kind == "MachinePool")' -)
    if [ "$MP" != "" ]; then
        echo ""
        echo "Waiting for the machine pool to be ready"
        kubectl ${namespace_setting} wait --timeout=30m --for=condition=ready machinepool -l cluster.x-k8s.io/cluster-name=$CLUSTER_NAME
    fi

    echo ""
    echo "Setup CAPI in management cluster: $CLUSTER_NAME"
    kubectl ${namespace_setting} get secret $CLUSTER_NAME-kubeconfig -o jsonpath={.data.value} | base64 --decode > ~/mgmt.kubeconfig
    if [ -z "$(kubectl --kubeconfig ~/mgmt.kubeconfig get ns capi-system)" ] ; then
        clusterctl init  --kubeconfig ~/mgmt.kubeconfig -i $INFRA_PROVIDERS -c $CONTROLPLANE_PROVIDERS -b $BOOTSTRAP_PROVIDERS --core cluster-api:v0.3.12
    fi
    kubectl wait --kubeconfig ~/mgmt.kubeconfig --for=condition=ready --timeout=2m pod -l cluster.x-k8s.io/provider=control-plane-eks -n capi-webhook-system
    kubectl wait --kubeconfig ~/mgmt.kubeconfig --for=condition=ready --timeout=2m pod -l cluster.x-k8s.io/provider=infrastructure-aws -n capi-webhook-system
    kubectl wait --kubeconfig ~/mgmt.kubeconfig --for=condition=ready --timeout=2m pod -l cluster.x-k8s.io/provider=cluster-api -n capi-webhook-system
    kubectl wait --kubeconfig ~/mgmt.kubeconfig --for=condition=ready --timeout=2m pod -l cluster.x-k8s.io/provider=bootstrap-kubeadm -n capi-webhook-system
    kubectl wait --kubeconfig ~/mgmt.kubeconfig --for=condition=ready --timeout=2m pod -l cluster.x-k8s.io/provider=control-plane-kubeadm -n capi-webhook-system

    echo ""
    echo "Pivot into the new management cluster"
    # NOTE: we get the secret again as the token is short lived
    kubectl ${namespace_setting} get secret $CLUSTER_NAME-kubeconfig -o jsonpath={.data.value} | base64 --decode > ~/mgmt.kubeconfig
    clusterctl move --to-kubeconfig ~/mgmt.kubeconfig

    echo ""
    echo "Get user kubeconfig"
    kubectl ${namespace_setting} get secret $CLUSTER_NAME-user-kubeconfig -o jsonpath={.data.value} | base64 --decode > ${CREDS_DIR}/mgmt.kubeconfig

    if [ "$KEEP_KIND" == "false" ]; then
        echo ""
        echo "Delete bootstrap cluster"
        kind delete cluster --name=wkp-mgmt-bootstrap
    fi
fi
export KUBECONFIG=${CREDS_DIR}/mgmt.kubeconfig

utils/deploy-wkp.sh

exit

./utils/kubeseal-aws-account.sh ${debug} --key-file clusters/mgmt01/pub-sealed-secrets.pem --aws-account-name account-one cluster-specs/mgmt01/eks-accounts/account-one-secret.yaml
./utils/kubeseal-aws-account.sh ${debug} --key-file clusters/mgmt01/pub-sealed-secrets.pem --aws-account-name account-two cluster-specs/mgmt01/eks-accounts/account-two-secret.yaml

if [ -z "`git status | grep 'nothing to commit, working tree clean'`" ] ; then
    git add -A;git commit -a -m "flux and kubeseal setup for eks mgmt01 cluster"; git push
fi

kubectl apply -f clusters/mgmt01/self.yaml

echo ""
echo "Waiting for tenant clusters to be ready"
kubectl wait --for=condition=ready --timeout 1h -n tenants cluster/tenant01
kubectl wait --for=condition=ready --timeout 1h -n tenants cluster/tenant02

kubectl -n tenants get secret tenant01-user-kubeconfig -o jsonpath={.data.value} | base64 --decode > ${CREDS_DIR}/tenant01.kubeconfig
export KUBECONFIG=${CREDS_DIR}/tenant01.kubeconfig
./utils/deploy-flux.sh ${debug} cluster-specs/tenant01/flux
./utils/deploy-kubeseal.sh ${debug} clusters/tenant01

if [ -z "`git status | grep 'nothing to commit, working tree clean'`" ] ; then
    git add -A;git commit -a -m "flux and kubeseal setup for eks tenant01 cluster"; git push
fi

kubectl apply -f clusters/tenant01/self.yaml

export KUBECONFIG=${CREDS_DIR}/mgmt.kubeconfig
kubectl -n tenants get secret tenant02-user-kubeconfig -o jsonpath={.data.value} | base64 --decode > ${CREDS_DIR}/tenant02.kubeconfig

source $CREDS_DIR/account-two.sh
export KUBECONFIG=${CREDS_DIR}/tenant02.kubeconfig
./utils/deploy-flux.sh ${debug} cluster-specs/tenant02/flux
./utils/deploy-kubeseal.sh ${debug} clusters/tenant02

if [ -z "`git status | grep 'nothing to commit, working tree clean'`" ] ; then
    git add -A;git commit -a -m "flux and kubeseal setup for eks tenant02 cluster"; git push
fi
kubectl apply -f clusters/tenant02/self.yaml
