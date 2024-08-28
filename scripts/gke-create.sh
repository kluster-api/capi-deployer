#!/bin/bash

sudo su
HOME="/root"
cd ${HOME}

set -eou pipefail

export GCP_PROJECT="{{ .gcp_project }}"
export GCP_B64ENCODED_CREDENTIALS="{{ .gcp_b64encoded_credentials }}"
export GCP_REGION="{{ .gcp_region }}"
export CLUSTER_NAME="{{ .cluster_name }}"
export GCP_NETWORK_NAME="{{ .gcp_network_name }}"
export SUBNET_CIDR="{{ .subnet_cidr }}"
export KUBERNETES_VERSION="{{ .kubernetes_version }}"
export GCP_CONTROL_PLANE_MACHINE_TYPE="{{ .gcp_control_plane_machine_type }}"
export GCP_NODE_MACHINE_TYPE="{{ .gcp_node_machine_type }}"
export WORKER_MACHINE_COUNT={{ .worker_machine_count }}

export EXP_CAPG_GKE=true
export EXP_MACHINE_POOL=true

# for logs...
export NATS_CREDS="{{ .nats_creds }}"
export NATS_SERVER="{{ .nats_server }}"
export SHIPPER_SUBJECT="{{ .shipper_subject }}"

curl -fsSLO https://github.com/bytebuilders/nats-logger/releases/latest/download/nats-logger-linux-amd64.tar.gz
tar -xzf nats-logger-linux-amd64.tar.gz
chmod +x nats-logger-linux-amd64
mv nats-logger-linux-amd64 nats-logger

exec >/root/create-script.log 2>&1
SHIPPER_FILE=/root/create-script.log ./nats-logger &

KIND_VERSION="{{ .kind_version }}"
CLUSTERCTL_VERSION="{{ .clusterctl_version }}"
KIND_IMAGE_VERSION="{{ .kind_image_version }}"
CLUSTER_NAMESPACE=capi-cluster

# for generating infrastructure component
CLUSTER_API_VERSION="{{ .cluster_api_version }}"
INFRASTRUCTURE_VERSION="{{ .infrastructure_version }}"

PROVIDER_NAME=gcp
SERVICE_NAME=gke

# http://redsymbol.net/articles/bash-exit-traps/
# https://unix.stackexchange.com/a/308209
rollback() {
    kubectl delete cluster $CLUSTER_NAME -n $CLUSTER_NAMESPACE || true
}

function finish {
    result=$?
    if [ $result -ne 0 ]; then
        rollback || true
    fi

    if [ $result -ne 0 ]; then
        echo "Cluster provision: Task failed !"
    else
        echo "Cluster provision: Task completed successfully !"
    fi

    sleep 5s

    [ ! -f /tmp/result.txt ] && echo $result >/tmp/result.txt
}
trap finish EXIT

#architecture
case $(uname -m) in
    x86_64)
        sys_arch=amd64
        ;;
    arm64 | aarch64)
        sys_arch=arm64
        ;;
    ppc64le)
        sys_arch=ppc64le
        ;;
    s390x)
        sys_arch=s390x
        ;;
    *)
        sys_arch=amd64
        ;;
esac

#opearating system
opsys=windows
if [[ "$OSTYPE" == linux* ]]; then
    opsys=linux
elif [[ "$OSTYPE" == darwin* ]]; then
    opsys=darwin
fi

timestamp() {
    date +"%Y/%m/%d %T"
}

log() {
    local type="$1"
    local msg="$2"
    local script_name=${0##*/}
    echo "$(timestamp) [$script_name] [$type] $msg"
}

retry() {
    local retries="$1"
    shift

    local count=0
    local wait=5
    until "$@"; do
        exit="$?"
        if [ $count -lt $retries ]; then
            log "INFO" "Attempt $count/$retries. Command exited with exit_code: $exit. Retrying after $wait seconds..."
            sleep $wait
        else
            log "INFO" "Command failed in all $retries attempts with exit_code: $exit. Stopping trying any further...."
            return $exit
        fi
        count=$(($count + 1))
    done
    return 0
}

wait_for_docker() {
    while [[ -z "$(! docker stats --no-stream 2>/dev/null)" ]]; do
        echo "Waiting for docker to start"
        sleep 30s
    done
}

install_yq() {
    snap install yq
}

#install docker from: https://kind.sigs.k8s.io/docs/user/quick-start/#installing-from-source
install_kind() {
    echo "--------------creating kind--------------"

    local cmnd="curl -Lo ./kind https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${sys_arch}"
    retry 5 ${cmnd}

    chmod +x ./kind

    cmnd="mv ./kind /usr/local/bin/kind"
    retry 5 ${cmnd}
}

create_kind_cluster() {
    #create cluster
    cmnd="kind delete cluster"
    retry 5 ${cmnd}

    sleep 5s

    kind create cluster --image=kindest/node:${KIND_IMAGE_VERSION}
    kubectl wait --for=condition=ready pods --all -A --timeout=5m
}

#download kubectl from: https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/
install_kubectl() {
    echo "--------------installing kubectl--------------"
    ltral="https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/${opsys}/${sys_arch}/kubectl"
    local cmnd="curl -LO"
    retry 5 ${cmnd} ${ltral}

    ltral="https://dl.k8s.io/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/${opsys}/${sys_arch}/kubectl.sha256"
    cmnd="curl -LO"
    retry 5 ${cmnd} ${ltral}

    echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check

    cmnd="install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl"
    retry 5 ${cmnd}
}

#download clusterctl from: https://cluster-api.sigs.k8s.io/user/quick-start.html
install_clusterctl() {
    local cmnd="curl -L https://github.com/kubernetes-sigs/cluster-api/releases/download/${CLUSTERCTL_VERSION}/clusterctl-${opsys}-${sys_arch} -o clusterctl"
    retry 5 ${cmnd}

    cmnd="install -o root -g root -m 0755 clusterctl /usr/local/bin/clusterctl"
    retry 5 ${cmnd}

    clusterctl version
}

#download helm from apt (debian/ubuntu) https://helm.sh/docs/intro/install/
install_helm() {
    echo "--------------installing helm--------------"
    local cmnd="curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3"
    retry 5 ${cmnd}

    chmod 700 get_helm.sh

    cmnd="./get_helm.sh"
    retry 5 ${cmnd}
}

generate_infrastructure_config_files() {

    echo "-----------generating infrastructure configuration files--------------"

    # folder structure: {basepath}/{provider-name}/{version}/{components.yaml}
    mkdir -p assets/infrastructure-${PROVIDER_NAME}/${INFRASTRUCTURE_VERSION} assets/bootstrap-kubeadm/${CLUSTER_API_VERSION} assets/cluster-api/${CLUSTER_API_VERSION} assets/control-plane-kubeadm/${CLUSTER_API_VERSION}

    # get the files from cdn.appscode.com
    wget -P assets/cluster-api/${CLUSTER_API_VERSION} https://cdn.appscode.com/files/cluster-api/${CLUSTER_API_VERSION}/core-components.yaml
    wget -P assets/cluster-api/${CLUSTER_API_VERSION} https://cdn.appscode.com/files/cluster-api/${CLUSTER_API_VERSION}/metadata.yaml
    wget -P assets/bootstrap-kubeadm/${CLUSTER_API_VERSION} https://cdn.appscode.com/files/cluster-api/${CLUSTER_API_VERSION}/bootstrap-components.yaml
    wget -P assets/bootstrap-kubeadm/${CLUSTER_API_VERSION} https://cdn.appscode.com/files/cluster-api/${CLUSTER_API_VERSION}/metadata.yaml
    wget -P assets/control-plane-kubeadm/${CLUSTER_API_VERSION} https://cdn.appscode.com/files/cluster-api/${CLUSTER_API_VERSION}/control-plane-components.yaml
    wget -P assets/control-plane-kubeadm/${CLUSTER_API_VERSION} https://cdn.appscode.com/files/cluster-api/${CLUSTER_API_VERSION}/metadata.yaml
    wget -P assets/infrastructure-${PROVIDER_NAME}/${INFRASTRUCTURE_VERSION} https://cdn.appscode.com/files/cluster-api-provider-${PROVIDER_NAME}/${INFRASTRUCTURE_VERSION}/infrastructure-components.yaml
    wget -P assets/infrastructure-${PROVIDER_NAME}/${INFRASTRUCTURE_VERSION} https://cdn.appscode.com/files/cluster-api-provider-${PROVIDER_NAME}/${INFRASTRUCTURE_VERSION}/cluster-template-${SERVICE_NAME}.yaml
    wget -P assets/infrastructure-${PROVIDER_NAME}/${INFRASTRUCTURE_VERSION} https://cdn.appscode.com/files/cluster-api-provider-${PROVIDER_NAME}/${INFRASTRUCTURE_VERSION}/metadata.yaml

    # generate the config.yaml file
    cat <<EOF >assets/config.yaml
providers:
  - name: "cluster-api"
    type: "CoreProvider"
    url: "/root/assets/cluster-api/$CLUSTER_API_VERSION/core-components.yaml"
  - name: "kubeadm"
    type: "BootstrapProvider"
    url: "/root/assets/bootstrap-kubeadm/$CLUSTER_API_VERSION/bootstrap-components.yaml"
  - name: "kubeadm"
    type: "ControlPlaneProvider"
    url: "/root/assets/control-plane-kubeadm/$CLUSTER_API_VERSION/control-plane-components.yaml"
  - name: "${PROVIDER_NAME}"
    type: "InfrastructureProvider"
    url: "/root/assets/infrastructure-${PROVIDER_NAME}/$INFRASTRUCTURE_VERSION/infrastructure-components.yaml"
overridesFolder: "/root/assets"
EOF
}

install_cert_manager() {
    local kubeconfig="$1"
    echo "-----------installing cert-manager--------------"
    cat <<EOF >cert-manager-values.yaml
cainjector:
  image:
    repository: quay.io/jetstack/cert-manager-cainjector
extraArgs:
- --feature-gates=AdditionalCertificateOutputFormats=true
- --feature-gates=ExperimentalGatewayAPISupport=true
image:
  repository: quay.io/jetstack/cert-manager-controller
installCRDs: true
webhook:
  image:
    repository: quay.io/jetstack/cert-manager-webhook
EOF
    local cmnd="helm upgrade -i gateway oci://ghcr.io/appscode-charts/gateway-api -n cert-manager --create-namespace --version=v1.0.0"
    retry 5 ${cmnd} --kubeconfig=${kubeconfig}
    cmnd="helm upgrade -i cert-manager oci://ghcr.io/appscode-charts/cert-manager -n cert-manager --create-namespace --version=v1.14.1 --values=cert-manager-values.yaml"
    retry 5 ${cmnd} --kubeconfig=${kubeconfig}

    echo "waiting for cert-manager pods to be ready..."
    kubectl wait --for=condition=ready pods --all -n cert-manager --timeout=10m --kubeconfig=${kubeconfig}
}

# initialize the cluster with gcp infrastructure
init_infrastructure() {
    local kubeconfig="$1"
    echo "-----------initializing infrastructure ${PROVIDER_NAME}--------------"

    # install cert-manager
    install_cert_manager "${kubeconfig}"

    cmnd="clusterctl init --infrastructure ${PROVIDER_NAME}"
    retry 5 ${cmnd} --config=assets/config.yaml --kubeconfig=${kubeconfig}

    echo "waiting for capi pods to be ready..."
    kubectl wait --for=condition=ready pods --all -n capg-system --timeout=10m --kubeconfig=${kubeconfig}
    kubectl wait --for=condition=ready pods --all -n capi-kubeadm-bootstrap-system --timeout=10m --kubeconfig=${kubeconfig}
    kubectl wait --for=condition=ready pods --all -n capi-kubeadm-control-plane-system --timeout=10m --kubeconfig=${kubeconfig}
    kubectl wait --for=condition=ready pods --all -n capi-system --timeout=10m --kubeconfig=${kubeconfig}
}

# add subnet cidr to cluster template
configure_yaml() {
    curl -fsSLO https://github.com/bytebuilders/capi-config/releases/download/v0.0.1/capi-config-linux-amd64.tar.gz
    tar -xzf capi-config-linux-amd64.tar.gz
    cp capi-config-linux-amd64 /bin
    capi-config-linux-amd64 capg </root/cluster.yaml >/root/configured-cluster.yaml
}

create_gke_cluster() {
    echo "Creating gke Cluster"

    cmnd="clusterctl generate cluster"

    kubectl create ns $CLUSTER_NAMESPACE
    retry 5 ${cmnd} ${CLUSTER_NAME} --flavor $SERVICE_NAME -n $CLUSTER_NAMESPACE --config=assets/config.yaml >/root/cluster.yaml

    configure_yaml
    kubectl apply -f /root/configured-cluster.yaml

    echo "creating cluster..."
    kubectl wait --for=condition=ready cluster --all -A --timeout=30m
    clusterctl get kubeconfig ${CLUSTER_NAME} -n $CLUSTER_NAMESPACE >${HOME}/kubeconfig
}

pivot_cluster() {
    init_infrastructure "${HOME}/kubeconfig"
    kubectl wait --kubeconfig=${HOME}/kubeconfig --for=condition=ready pods --all --namespace capg-system --timeout=20m

    clusterctl move --to-kubeconfig=${HOME}/kubeconfig -n $CLUSTER_NAMESPACE
}

# Temporary until capg release
update_capg_image() {
    local kubeconfig="$1"

    local cmnd="kubectl set image -n capg-system deployment/capg-controller-manager manager=shaad7/cluster-api-gcp-controller-amd64:apr --kubeconfig=${kubeconfig}"
    retry 5 ${cmnd}

    kubectl wait --for=condition=ready pods --all --namespace capg-system --timeout=10m --kubeconfig=${kubeconfig} || true

}

create_credential_secret() {
    echo "$GCP_B64ENCODED_CREDENTIALS" | base64 --decode >/root/gcp-credentials.json
    cmnd="kubectl create secret generic gcp-credential -n ${CLUSTER_NAMESPACE} --from-file=credential_json=/root/gcp-credentials.json --kubeconfig=${HOME}/kubeconfig"
    retry 5 ${cmnd}
}

init() {
    wait_for_docker

    install_yq
    install_kind
    install_kubectl

    sleep 60s

    install_helm
    create_kind_cluster
    install_clusterctl

    generate_infrastructure_config_files
    init_infrastructure "${HOME}/.kube/config"
    update_capg_image "${HOME}/.kube/config"
    create_gke_cluster
    pivot_cluster
    update_capg_image "${HOME}/kubeconfig"
    create_credential_secret
}
init
