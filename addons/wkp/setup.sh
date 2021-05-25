#!/usr/bin/env bash
# shellcheck shell=bash

case "${TRACE_SETUP}" in
    y|Y|yes|YES|t|T|true|TRUE|1)
        set -x
        ;;
esac

set -euo pipefail

unset CD_PATH
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}" || exit 1

. lib/functions.sh
. lib/eksctl.sh

# user-overrideable via ENV
if command -v sudo >/dev/null 2>&1; then
    sudo="${sudo:-"sudo"}"
else
    sudo="${sudo}"
fi

export PATH="${SCRIPT_DIR}/../bin:$PATH"


# Parameters
WK_EXECUTABLE="${1}"
VERBOSITY_FLAG="${2:-""}"
if [ "${VERBOSITY_FLAG}" == "--verbose" ]; then
    VERBOSITY=true
else
    VERBOSITY=false
fi
SKIP_PREFLIGHT_CHECKS_FLAG="${3:-""}"
if [ "${SKIP_PREFLIGHT_CHECKS_FLAG}" == "--skip-preflight-checks" ]; then
    SKIP_PREFLIGHT_CHECKS=true
else
    SKIP_PREFLIGHT_CHECKS=false
fi

CREATE_CLUSTER="${CREATE_CLUSTER:-"1"}"
GIT_PATH="${GIT_PATH:-"/cluster/platform"}"
WKP_DEBUG="${WKP_DEBUG:-"false"}"
WKP_DEBUG=$(bool "${WKP_DEBUG}")
CONFIG_FILE="${SCRIPT_DIR}/config.yaml"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-""}"
SKIP_COMPONENTS="${SKIP_COMPONENTS:-""}"
USE_LOAD_BALANCER_FOR_FOOTLOOSE="${USE_LOAD_BALANCER_FOR_FOOTLOOSE:-"true"}"
WKP_CLUSTER_COMPONENTS_IMAGE=${WKP_CLUSTER_COMPONENTS_IMAGE:-$(grep 'clusterComponents:' ../cluster/platform/gitops-params.yaml | awk '{ print ($2 == "#") ? "" : $2 ;}')}
WKP_CLUSTER_COMPONENTS_IMAGE=${WKP_CLUSTER_COMPONENTS_IMAGE:-"docker.io/weaveworks/wkp-cluster-components:$("${WK_EXECUTABLE}" imagetag)"}
# Set up environment from config file
if ! ENV=$("${WK_EXECUTABLE}" config env "${CONFIG_FILE}"); then
    exit 1
fi
eval "${ENV}"

# For clusters with existing machines (i.e. wks-ssh track) check if we have root ssh access before creating a remote git repo, etc.
if [ "${SKIP_PREFLIGHT_CHECKS}" == "false" ]; then
    "${WK_EXECUTABLE}" setup check imagerepository "${CONFIG_FILE}" --image "${WKP_CLUSTER_COMPONENTS_IMAGE}" --verbose="${WKP_DEBUG}" || exit 1
    if [ "${TRACK}" == "wks-ssh" ]; then
        "${WK_EXECUTABLE}" setup check machines --disk-space "${CONFIG_FILE}" --verbose="${WKP_DEBUG}" || exit 1
    fi
fi

if [[ -z "${SEALED_SECRETS_KEY}" ]]; then
    echo "Generating the sealed secrets private key and certificate..."
    openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
        -subj "/" \
        -keyout "${SCRIPT_DIR}/sealed-secrets-key" \
        -out "${SCRIPT_DIR}/sealed-secrets-cert.crt" > /dev/null 2>&1
    export SEALED_SECRETS_KEY="${SCRIPT_DIR}/sealed-secrets-key"
    export SEALED_SECRETS_CERT="${SCRIPT_DIR}/sealed-secrets-cert.crt"
fi

# git_commit_if_changed adds specified files or directories and commits with the desired message if there are related differences.
# Non-existent files or directories are silently ignored.
# usage: <commit-message> <file_paths...>
git_commit_if_changed() {
    local message="${1}"; shift

    if [ "${#}" -gt 0 ]; then
        git add "${@}"
        if git diff-index --quiet HEAD "${@}"; then
            log "Unchanged: ${message}"
        else
            log "Committing: ${message}"
            git commit -m "${message}"
        fi
    fi
}

VERSION_PATH="${SCRIPT_DIR}/VERSION"
"${WK_EXECUTABLE}" version > "${VERSION_PATH}"
git_commit_if_changed "Save wk binary version" "${VERSION_PATH}"

# Create deploy key for a new git repo and create the remote repo
# If repo key already exists, skip remote repo creation
GIT_DEPLOY_KEY="${SCRIPT_DIR}/repo-key-${CLUSTER_NAME}"
if [ -n "${GIT_URL:-}" ]; then
    if [ ! -e "${GIT_DEPLOY_KEY}" ]; then
        echo "No deploy key found at ${GIT_DEPLOY_KEY}" >&2
        echo "Generating with:" >&2
        echo "  ssh-keygen -q -t rsa -b 4096 -C wk@weave.works -f ${GIT_DEPLOY_KEY} -N \"\"" >&2
        ssh-keygen -q -t rsa -b 4096 -C wk@weave.works -f "${GIT_DEPLOY_KEY}" -N ""

        deploy-key.sh --debug --pubkey-file ${GIT_DEPLOY_KEY}.pub --git-url ${GIT_URL}
    fi

    git remote rm origin 2>/dev/null || echo "No origin found: OK"
    echo "Adding origin..."
    git remote add origin "${GIT_URL}"

    GIT_HOSTNAME=$(ssh_host_address "${GIT_URL}")
    echo "Saving remote keys for host ${GIT_HOSTNAME}..."
    KNOWN_HOSTS_PATH="${SCRIPT_DIR}/../cluster/platform/ssh_config/known_hosts"
    ssh-keyscan \
        -p "$(ssh_port "${GIT_HOSTNAME}")" \
        "$(ssh_strip_port "${GIT_HOSTNAME}")" \
        > "${KNOWN_HOSTS_PATH}"

    echo "Testing connecting to remote git provider..."
    ssh -oBatchMode=yes -o UserKnownHostsFile="${KNOWN_HOSTS_PATH}" \
        -p "$(ssh_port "$(ssh_user_and_host_address "${GIT_URL}")")" \
        -T "$(ssh_strip_port "$(ssh_user_and_host_address "${GIT_URL}")")" \
        || echo "Warning! Failed to connect to git repo over ssh"

    git_commit_if_changed "Add known_hosts" \
        "${KNOWN_HOSTS_PATH}"

    if git push --set-upstream origin master ; then
        echo "Connection to remote git provider ok."
    elif [ ${GIT_PROVIDER} == "gitlab" ]; then
        echo ""
        echo "Gitlab repositories need to be created before deploying WKP." >&2
        echo "Please refer to the user-guide section \"Git Config Repository\" for more information." >&2
        echo "To launch the user-guide run: $ wk user-guide" >&2
        exit 1
    else
        echo ""
        echo "Unable to push to origin." >&2
        echo "Please check if 'gitUrl' is set in config.yaml and you have write access." >&2
        exit 1
    fi

else
    # Create deploy key for new remote git repo and create repo
    # If repo key already exists, skip repo creation
    REPO_URL="git@github.com:${GIT_PROVIDER_ORG}/${CLUSTER_NAME}"
    if git ls-remote "$REPO_URL" >&/dev/null; then
        if [ ! -e "${GIT_DEPLOY_KEY}" ]; then
            echo "Repository named '${CLUSTER_NAME}' already exists but no local deploy key exists." >&2
            echo "It appears that the existing repository was not created via 'wk setup'". >&2
            echo "Please choose a different cluster name or rename/delete your existing repository." >&2
            exit 1
        fi
        git remote show origin 2>&1 | grep -q 'local out of date' &&
            echo "The upstream repository named '${CLUSTER_NAME}' has changed. Please integrate the changes." >&2 && exit 1
    else
        if [ ! -e "${GIT_DEPLOY_KEY}" ]; then
            echo "No deploy key found at ${GIT_DEPLOY_KEY}"
            echo "Generating with:"
            echo "  ssh-keygen -q -t rsa -b 4096 -C wk@weave.works -f ${GIT_DEPLOY_KEY} -N \"\""
            ssh-keygen -q -t rsa -b 4096 -C wk@weave.works -f "${GIT_DEPLOY_KEY}" -N ""
        fi
        (
            cd "${SCRIPT_DIR}/.."
            "${WK_EXECUTABLE}" gitops newrepo \
                --verbose="${WKP_DEBUG}" \
                --git-provider-org="${GIT_PROVIDER_ORG}" \
                --repository-name="${CLUSTER_NAME}" \
                --git-private-key-file="${GIT_DEPLOY_KEY}"
        )
    fi
fi

# Store deploy key and image pull information encrypted in git repository
kubectl create secret generic git-deploy-key \
    --dry-run=true --type=Opaque --output json \
    --namespace=weavek8sops \
    --from-literal="identity=$(cat "${GIT_DEPLOY_KEY}")" \
    | kubeseal --cert="${SEALED_SECRETS_CERT}" --format=yaml > "git-deploy-key.yaml"

kubectl create secret generic image-pull-information \
    --dry-run=true --type=Opaque --output json \
    --namespace=weavek8sops \
    --from-literal="username=${DOCKER_IO_USER}" \
    --from-literal="password=$(cat "${DOCKER_IO_PASSWORD_FILE}")" \
    | kubeseal --cert="${SEALED_SECRETS_CERT}" --format=yaml > "image-pull-information.yaml"

#
# FIXME: re-eval use of 
#  set -euo pipefail
# at top of this file.
# https://mywiki.wooledge.org/BashPitfalls#pipefail
#
# For now, allow non-zero exit codes in pipes as `tr` is probably still
# printing after head takes what it needs
#
set +o pipefail
nats_auth_token=$(LC_ALL=C tr -dc '[:alnum:]' < /dev/urandom | head -c20)
set -o pipefail

kubectl create secret generic nats-env-vars-secret \
    --dry-run=true --type=Opaque --output json \
    --namespace=wkp-gitops-repo-broker \
    --from-literal="NATS_AUTH_TOKEN=${nats_auth_token}" \
    | kubeseal --cert="${SEALED_SECRETS_CERT}" --format=yaml > "${SCRIPT_DIR}/../cluster/manifests/mccp/nats-env-vars-secret.yaml"

(
    cd "${SCRIPT_DIR}/.."
    "${WK_EXECUTABLE}" gitops generate-secrets \
        --verbose="${WKP_DEBUG}" \
        --git-private-key-file="${GIT_DEPLOY_KEY}" \
        --docker-io-user="${DOCKER_IO_USER}" \
        --docker-io-password-file="${DOCKER_IO_PASSWORD_FILE}" \
        --sealed-secrets-cert="${SEALED_SECRETS_CERT}"
)
git_commit_if_changed "Add gitops secrets" \
    "${SCRIPT_DIR}/git-deploy-key.yaml" \
    "${SCRIPT_DIR}/image-pull-information.yaml" \
    "${SCRIPT_DIR}/../cluster/platform/gitops-secrets.yaml" \
    "${SCRIPT_DIR}/../cluster/manifests/mccp/nats-env-vars-secret.yaml" \
    "${SEALED_SECRETS_CERT}"

kubeconfig_flag=""
if [[ "${KUBECONFIG_PATH}" != "" ]]; then
    kubeconfig_flag="--kubeconfig ${KUBECONFIG_PATH}"
fi

config_backend() {
    sed -n -e 's/^backend: *\(.*\)/\1/p' "${SCRIPT_DIR}/footloose-config.yaml"
}

set_config_backend() {
    local tmp=.footloose-config.yaml.tmp

    sed -e "s/^backend: .*$/backend: ${1}/" "${SCRIPT_DIR}/footloose-config.yaml" >"${tmp}" &&
        mv "${tmp}" "${SCRIPT_DIR}/footloose-config.yaml" &&
        rm -f "${tmp}"
}

do_footloose() {
    if [ "$(config_backend)" == "ignite" ]; then
        $sudo env "PATH=${PATH}" footloose "${@}"
    else
        footloose "${@}"
    fi
}

if git_current_branch >/dev/null 2>&1; then
    log "Using git branch: $(git_current_branch)"
else
    error "Please checkout a git branch."
fi

git_remote="$(git config --get "branch.$(git_current_branch).remote" || true)" # fallback to "", user may override

"${WK_EXECUTABLE}" gitops install \
    --git-url="$(git_ssh_url "$(git_remote_fetchurl "${git_remote}")")" \
    --git-branch="$(git_current_branch)" \
    --git-path="${GIT_PATH}" \
    --wkp-cluster-components-image="${WKP_CLUSTER_COMPONENTS_IMAGE}" \
    --verbose="${WKP_DEBUG}"

if [ "${TRACK}" == "wks-footloose" ]; then
    # init footloose from main config file
    ${WK_EXECUTABLE} config footloose "${CONFIG_FILE}" >"${SCRIPT_DIR}/footloose-config.yaml"

    # On macOS, we only support the docker backend.
    if [ "$(goos)" == "darwin" ]; then
        set_config_backend docker
    fi
    check_command docker
    log "Creating footloose manifest"
    jk generate -f "${SCRIPT_DIR}/footloose-config.yaml" -f "${CONFIG_FILE}" "${SCRIPT_DIR}/setup.js"

    cluster_key="cluster-key"
    if [ ! -f "${cluster_key}" ]; then
        # Create the cluster ssh key with the user credentials.
        log "Creating SSH key"
        ssh-keygen -q -t rsa -b 4096 -C wk-quickstart@weave.works -f "${cluster_key}" -N ""
    fi
    log "Creating virtual machines"
    do_footloose create

    if [ "${SKIP_PREFLIGHT_CHECKS}" == "false" ]; then
        "${WK_EXECUTABLE}" setup check machines --disk-space "${CONFIG_FILE}" --verbose="${WKP_DEBUG}" || exit 1
    fi

    log "Creating Cluster API manifests"
    status="${SCRIPT_DIR}/footloose-status.yaml"
    do_footloose status -o json >"${status}"
    jk generate \
        -f "${SCRIPT_DIR}/footloose-config.yaml" \
        -f "${status}" \
        -f "${CONFIG_FILE}" \
        -p "kubernetesVersion=${KUBERNETES_VERSION}" \
        "${SCRIPT_DIR}/setup.js"
    rm -f "${status}"

    log "Setting up load balancer if needed"
    if [ "${USE_LOAD_BALANCER_FOR_FOOTLOOSE}" == "true" ]; then
        ${WK_EXECUTABLE} setup haproxy configure --config-file="${CONFIG_FILE}"
    fi

    # Create cluster now that we have machines (so we can retrieve the load balancer address)
    ${WK_EXECUTABLE} config cluster "${CONFIG_FILE}" >"${SCRIPT_DIR}/cluster.yaml"

    log "Updating container images and git parameters"
    "${WK_EXECUTABLE}" init \
        --git-url="$(git_ssh_url "$(git_remote_fetchurl "${git_remote}")")" \
        --git-branch="$(git_current_branch)" \
        --git-path=setup \
        --dependency-file="${SCRIPT_DIR}/dependencies.toml" \
        --verbose="${WKP_DEBUG}"
    log "Pushing initial cluster configuration"
    git_commit_if_changed "Initial cluster configuration" \
        "${SCRIPT_DIR}/flux.yaml" \
        "${SCRIPT_DIR}/footloose-config.yaml" \
        "${SCRIPT_DIR}/footloose.yaml" \
        "${SCRIPT_DIR}/cluster.yaml" \
        "${SCRIPT_DIR}/machines.yaml" \
        "${SCRIPT_DIR}/config.yaml" \
        "${SCRIPT_DIR}/git-deploy-key.yaml" \
        "${SCRIPT_DIR}/image-pull-information.yaml" \
        "${SCRIPT_DIR}/weave-net.yaml" \
        "${SCRIPT_DIR}/../cluster/platform/gitops-params.yaml"
    git push "${git_remote}" HEAD

    log "Installing Kubernetes cluster"
    apply_args=(
        "--git-url=$(git_ssh_url "$(git_remote_fetchurl "${git_remote}")")"
        "--git-branch=$(git_current_branch)"
        "--git-deploy-key=${GIT_DEPLOY_KEY}"
        "--git-path=setup"
    )
    "${WK_EXECUTABLE}" apply "${apply_args[@]}" --verbose="${WKP_DEBUG}"
    "${WK_EXECUTABLE}" kubeconfig "${apply_args[@]}" --verbose="${WKP_DEBUG}"

    if [ "${USE_LOAD_BALANCER_FOR_FOOTLOOSE}" == "true" ] && \
       [ "$(footloose_master_count "${SCRIPT_DIR}/footloose-config.yaml")" != "1" ]; then
        log "Updating kubeconfig with load balancer endpoint"
        "${WK_EXECUTABLE}" setup haproxy update-kubeconfig \
             --api-server-endpoint="127.0.0.1:$((6442+$(footloose_machine_count "${SCRIPT_DIR}/footloose.yaml")))" \
             --verbose="${WKP_DEBUG}"
    fi

elif [ "${TRACK}" == "wks-ssh" ]; then
    # Create cluster and machine manifests from main config file
    "${WK_EXECUTABLE}" config cluster "${CONFIG_FILE}" >"${SCRIPT_DIR}/cluster.yaml"
    "${WK_EXECUTABLE}" config machines "${CONFIG_FILE}" >"${SCRIPT_DIR}/machines.yaml"

    log "Updating container images and git parameters"
    "${WK_EXECUTABLE}" init \
        --git-url="$(git_ssh_url "$(git_remote_fetchurl "${git_remote}")")" \
        --git-branch="$(git_current_branch)" \
        --git-path=setup \
        --dependency-file="${SCRIPT_DIR}/dependencies.toml" \
        --verbose="${WKP_DEBUG}"

    log "Pushing initial cluster configuration"
    git_commit_if_changed "Initial cluster configuration" \
        "${SCRIPT_DIR}/flux.yaml" \
        "${SCRIPT_DIR}/cluster.yaml" \
        "${SCRIPT_DIR}/machines.yaml" \
        "${SCRIPT_DIR}/config.yaml" \
        "${SCRIPT_DIR}/git-deploy-key.yaml" \
        "${SCRIPT_DIR}/image-pull-information.yaml" \
        "${SCRIPT_DIR}/weave-net.yaml" \
        "${SCRIPT_DIR}/../cluster/platform/gitops-params.yaml"
    git push "${git_remote}" HEAD || log "Nothing to push"

    log "Installing Kubernetes cluster"
    apply_args=(
        "--git-url=$(git_ssh_url "$(git_remote_fetchurl "${git_remote}")")"
        "--git-branch=$(git_current_branch)"
        "--git-deploy-key=${GIT_DEPLOY_KEY}"
        "--git-path=setup"
    )
    apply_args+=("--ssh-key=${SSH_KEY_FILE}")
    "${WK_EXECUTABLE}" apply "${apply_args[@]}" --verbose="${WKP_DEBUG}"
    "${WK_EXECUTABLE}" kubeconfig "${apply_args[@]}" --verbose="${WKP_DEBUG}"

elif [ "${TRACK}" == "eks" ]; then
    REGION="${REGION:-"eu-west-3"}"
    if [[ "${CREATE_CLUSTER}" -gt 0 ]]; then
        case $(
            eksctl_cluster_exists "${REGION}" "${CLUSTER_NAME}"
            echo $?
        ) in
        0)
            error "Cluster ${CLUSTER_NAME} in ${REGION} already exists. If you really mean to recreate your cluster, please run 'cleanup.sh' first and then retry."
            ;;
        2)
            error "Checking whether the cluster exists failed unexpectedly."
            ;;
        esac

        EKSCTL_VERBOSITY=3
        if [ "${VERBOSITY}" == "true" ]; then
            EKSCTL_VERBOSITY=5
        fi

        # If an eksctl config file is set in config.yaml, pass that directly
        if [ "${EKSCTL_CONFIG_FILE:-""}" != "" ]; then
            if [[ ! "${EKSCTL_CONFIG_FILE}" -ef "${SCRIPT_DIR}"/eksctl-config.yaml ]]; then
                cp "${EKSCTL_CONFIG_FILE}" "${SCRIPT_DIR}"/eksctl-config.yaml
            fi
            git_commit_if_changed "Initial cluster configuration" \
                "${SCRIPT_DIR}/eksctl-config.yaml" \
                "${SCRIPT_DIR}/config.yaml" \
                "${SCRIPT_DIR}/git-deploy-key.yaml" \
                "${SCRIPT_DIR}/image-pull-information.yaml" \
                "${SCRIPT_DIR}/../cluster/platform/gitops-params.yaml"
            git push "${git_remote}" HEAD || log "Nothing to push"

            eksctl create cluster -f "${EKSCTL_CONFIG_FILE}" --verbose "${EKSCTL_VERBOSITY}"
        else
            # Generate eks cluster manifest from main config file
            "${WK_EXECUTABLE}" config eks "${CONFIG_FILE}" >"${SCRIPT_DIR}/../cluster/platform/clusters/default/wk-cluster.yaml"

            git_commit_if_changed "Initial cluster configuration" \
                "${SCRIPT_DIR}/../cluster/platform/clusters/default/wk-cluster.yaml" \
                "${SCRIPT_DIR}/config.yaml" \
                "${SCRIPT_DIR}/git-deploy-key.yaml" \
                "${SCRIPT_DIR}/image-pull-information.yaml" \
                "${SCRIPT_DIR}/../cluster/platform/gitops-params.yaml"
            git push "${git_remote}" HEAD || log "Nothing to push"

            # generate eksctl-compatible configuration from EKSCluster CRD
            EKSCTL_CONFIG=$(jk generate --stdout "${SCRIPT_DIR}/../cluster/platform/cluster-config.js")
            eksctl create cluster -f <(echo "${EKSCTL_CONFIG}") "${kubeconfig_flag}" --verbose "${EKSCTL_VERBOSITY}"
        fi
    fi
elif [ "${TRACK}" == "wks-components" ]; then
    SKIP_PROMPT="${SKIP_PROMPT:-"0"}"
    if [[ "${SKIP_PROMPT}" -ne 1 ]]; then
        echo "Installing WKP component to existing cluster using current context: $(kubectl config current-context)" >&2
        echo "Cluster nodes:"
        echo "$(kubectl get nodes)"
        echo ""

        #check_for_existing_sealed_secrets_and_flux
        check_cluster_version
    fi

    git_commit_if_changed "Initial cluster configuration" \
        "${SCRIPT_DIR}/config.yaml" \
        "${SCRIPT_DIR}/git-deploy-key.yaml" \
        "${SCRIPT_DIR}/image-pull-information.yaml" \
        "${SCRIPT_DIR}/../cluster/platform/gitops-params.yaml"
    git push "${git_remote}" HEAD || log "Nothing to push"
else # unknown
    echo "Unknown track: ${TRACK}" >&2
    exit 1
fi

# Sealed secrets installation
kubectl --namespace="kube-system" \
    create secret tls sealed-secrets-key \
    --cert="${SEALED_SECRETS_CERT}" \
    --key="${SEALED_SECRETS_KEY}"
kubectl --namespace="kube-system" \
    label secret sealed-secrets-key \
    sealedsecrets.bitnami.com/sealed-secrets-key=active \
    --overwrite=true
kubectl apply \
    --filename "${SCRIPT_DIR}/../cluster/manifests/sealed-secrets-controller.yaml" &> /dev/null
# Make sure the CRD is present before waiting on its condition
echo -n 'Waiting for sealed secret CRD installation...'
crd_tries=15
until kubectl get crd sealedsecrets.bitnami.com -n kube-system >/dev/null 2>&1;
do
    crd_tries="$(( crd_tries - 1 ))"
    if [ "${crd_tries}" = 0 ]; then
        echo # finish carriage return for `echo -n`
        exit 1
    fi
    echo -n '.'
    sleep 1
done
echo # finish carriage return for `echo -n`
echo 'sealed secret CRD installed.'
kubectl wait --for condition=established \
    --timeout=60s \
    crd/sealedsecrets.bitnami.com 2>&1

if [ "${SKIP_COMPONENTS}" == "true" ]; then
    echo "Skipping component installation."
    echo "Master node has been provisioned,"
    echo "additional nodes still being added to cluster."
    exit 0
fi

# Delete old flux before introducing wkp-flux
if [ "${TRACK}" == "wks-footloose" ] || [ "${TRACK}" == "wks-ssh" ]; then
    kubectl delete deployment flux --namespace weavek8sops
    kubectl delete deployment memcached --namespace weavek8sops
    kubectl delete serviceaccount flux --namespace weavek8sops
    git pull
    git rm "${SCRIPT_DIR}/flux.yaml"
    git commit -m "Remove initial bootstrap flux"
    git push "${git_remote}" HEAD
fi

# Make sure a non-master is running to receive the new flux pod
if [ "${TRACK}" == "wks-ssh" ] || [ "${TRACK}" == "wks-footloose" ]; then
    echo -n "Waiting for worker node"
    # Wait until a worker node state is ready or 10 minutes passed
    # 10minutes = 10 * 60 = 600s
    # 600s / 5s = 120
    worker_node_retries=120
    until kubectl wait --for condition=ready nodes -l '!node-role.kubernetes.io/master' >/dev/null 2>&1;
    do
        worker_node_retries="$(( worker_node_retries - 1 ))"
        if [ "${worker_node_retries}" = 0 ]; then
            echo # finish carriage return for `echo -n`
            exit 1
        fi
        echo -n '.'
        sleep 5
    done
    echo "done"
fi

"${WK_EXECUTABLE}" gitops start \
    --bootstrap-timeout=10m \
    --git-url="$(git_ssh_url "$(git_remote_fetchurl "${git_remote}")")" \
    --git-branch="$(git_current_branch)" \
    --git-private-key-file="${GIT_DEPLOY_KEY}" \
    --git-path="${GIT_PATH}" \
    --docker-io-user="${DOCKER_IO_USER}" \
    --docker-io-password-file="${DOCKER_IO_PASSWORD_FILE}" \
    --wkp-cluster-components-image="${WKP_CLUSTER_COMPONENTS_IMAGE}" \
    --verbose="${WKP_DEBUG}"

echo "Successfully created and initialized cluster: ${CLUSTER_NAME}"
echo ""
echo "Here are the sealed secret key and certificate, keep them in a safe place!"
echo "${SEALED_SECRETS_KEY}"
echo "${SEALED_SECRETS_CERT}"
echo ""
