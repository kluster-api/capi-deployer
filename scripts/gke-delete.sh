#!/bin/bash

sudo su
HOME="/root"
cd ${HOME}

set -eou pipefail

export GCP_B64ENCODED_CREDENTIALS="{{ .gcp_b64encoded_credentials }}"
export B64ENCODED_REMOTE_KUBECONFIG="{{ .b64encoded_remote_kubeconfig }}"

export EXP_MACHINE_POOL=true
export EXP_CAPG_GKE=true

# for logs...
export NATS_CREDS="{{ .nats_creds }}"
export NATS_SERVER="{{ .nats_server }}"
export SHIPPER_SUBJECT="{{ .shipper_subject }}"

curl -fsSLO https://github.com/bytebuilders/nats-logger/releases/latest/download/nats-logger-linux-amd64.tar.gz
tar -xzf nats-logger-linux-amd64.tar.gz
chmod +x nats-logger-linux-amd64
mv nats-logger-linux-amd64 nats-logger

exec >/root/delete-script.log 2>&1
SHIPPER_FILE=/root/delete-script.log ./nats-logger &

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
        echo "Cluster Deletion: Task failed !"
    else
        echo "Cluster Deletion: Task completed successfully !"
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

set_kubeconfig() {
    echo $B64ENCODED_REMOTE_KUBECONFIG | base64 --decode >/root/remote.kubeconfig
}

wait_for_docker() {
    while [[ -z "$(! docker stats --no-stream 2>/dev/null)" ]]; do
        echo "Waiting for docker to start"
        sleep 30s
    done
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

install_helm() {
    echo "--------------installing helm--------------"
    local cmnd="curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3"
    retry 5 ${cmnd}

    chmod 700 get_helm.sh

    cmnd="./get_helm.sh"
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

init_infrastructure() {
    local kubeconfig="$1"
    echo "-----------initializing infrastructure ${PROVIDER_NAME}--------------"

    # install cert-manager
    install_cert_manager "${kubeconfig}"

    cmnd="clusterctl init --infrastructure ${PROVIDER_NAME} --config=assets/config.yaml"
    retry 5 ${cmnd}

    echo "waiting for capi pods to be ready..."
    kubectl wait --for=condition=ready pods --all -n capg-system --timeout=10m --kubeconfig=${kubeconfig}
    kubectl wait --for=condition=ready pods --all -n capi-kubeadm-bootstrap-system --timeout=10m --kubeconfig=${kubeconfig}
    kubectl wait --for=condition=ready pods --all -n capi-kubeadm-control-plane-system --timeout=10m --kubeconfig=${kubeconfig}
    kubectl wait --for=condition=ready pods --all -n capi-system --timeout=10m --kubeconfig=${kubeconfig}
}

restart_capg_pod() {
    kubectl delete pod -n capg-system --all --kubeconfig=${HOME}/remote.kubeconfig
    kubectl wait --for=condition=ready pods --all --namespace capg-system --timeout=10m --kubeconfig=${HOME}/remote.kubeconfig
    sleep 2m
    kubectl wait --for=condition=ready gcpmanagedcontrolplane --all --namespace $CLUSTER_NAMESPACE --timeout=30m --kubeconfig=${HOME}/remote.kubeconfig
}

get_cluster_name() {
    CLUSTER_NAME=$(kubectl get cluster -A --kubeconfig=${HOME}/remote.kubeconfig | grep $CLUSTER_NAMESPACE | awk '{print $2}')
}

pivot_cluster() {
    echo "Pivoting Cluster to Kind Cluster "
    clusterctl move --to-kubeconfig=${HOME}/.kube/config --kubeconfig=${HOME}/remote.kubeconfig -n $CLUSTER_NAMESPACE
    sleep 1m
}

delete_cluster() {
    echo "Deleting Cluster $CLUSTER_NAME"
    kubectl delete cluster "$CLUSTER_NAME" -n $CLUSTER_NAMESPACE --kubeconfig=${HOME}/.kube/config
}

init() {
    wait_for_docker
    set_kubeconfig

    install_kind
    install_kubectl
    sleep 60s

    install_helm
    create_kind_cluster
    install_clusterctl

    generate_infrastructure_config_files
    init_infrastructure "${HOME}/.kube/config"
    restart_capg_pod

    get_cluster_name
    pivot_cluster
    delete_cluster
}
init
