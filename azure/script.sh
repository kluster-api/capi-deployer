#!/bin/bash

HOME="/home/ubuntu"
cd /root
set -xeo pipefail

apt-get -y update

rollback() {
    kubectl delete cluster $CLUSTER_NAME -n ${CLUSTER_NAMESPACE}
}

curl -fsSLO https://github.com/bytebuilders/nats-logger/releases/latest/download/nats-logger-linux-amd64.tar.gz
tar -xzvf nats-logger-linux-amd64.tar.gz
chmod +x nats-logger-linux-amd64
mv nats-logger-linux-amd64 /bin/nats-logger

PROVIDER_NAME=azure
SERVICE_NAME=aks

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

function timestamp() {
    date +"%Y/%m/%d %T"
}

function log() {
    local type="$1"
    local msg="$2"
    local script_name=${0##*/}
    echo "$(timestamp) [$script_name] [$type] $msg"
}

function retry {
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

install_wget() {
  apt install wget
}

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



install_clusterctl() {
    local cmnd="curl -L https://github.com/kubernetes-sigs/cluster-api/releases/download/${CLUSTERCTL}/clusterctl-${opsys}-${sys_arch} -o clusterctl"
    retry 5 ${cmnd}

    cmnd="install -o root -g root -m 0755 clusterctl /usr/local/bin/clusterctl"
    retry 5 ${cmnd}

    clusterctl version
}

generate_infrastructure_config_files() {

    echo "-----------generating infrastructure configuration files--------------"

    # folder structure: {basepath}/{provider-name}/{version}/{components.yaml}
    mkdir -p ${HOME}/assets/infrastructure-${PROVIDER_NAME}/${INFRASTRUCTURE_VERSION} /root/assets/bootstrap-kubeadm/${CLUSTER_API_VERSION} /root/assets/cluster-api/${CLUSTER_API_VERSION} /root/assets/control-plane-kubeadm/${CLUSTER_API_VERSION}

    wget -P ${HOME}/assets/cluster-api/${CLUSTER_API_VERSION} https://cdn.appscode.com/files/cluster-api/${CLUSTER_API_VERSION}/core-components.yaml
    wget -P ${HOME}/assets/cluster-api/${CLUSTER_API_VERSION} https://cdn.appscode.com/files/cluster-api/${CLUSTER_API_VERSION}/metadata.yaml
    wget -P ${HOME}/assets/bootstrap-kubeadm/${CLUSTER_API_VERSION} https://cdn.appscode.com/files/cluster-api/${CLUSTER_API_VERSION}/bootstrap-components.yaml
    wget -P ${HOME}/assets/bootstrap-kubeadm/${CLUSTER_API_VERSION} https://cdn.appscode.com/files/cluster-api/${CLUSTER_API_VERSION}/metadata.yaml
    wget -P ${HOME}/assets/control-plane-kubeadm/${CLUSTER_API_VERSION} https://cdn.appscode.com/files/cluster-api/${CLUSTER_API_VERSION}/control-plane-components.yaml
    wget -P ${HOME}/assets/control-plane-kubeadm/${CLUSTER_API_VERSION} https://cdn.appscode.com/files/cluster-api/${CLUSTER_API_VERSION}/metadata.yaml
    wget -P ${HOME}/assets/infrastructure-${PROVIDER_NAME}/${INFRASTRUCTURE_VERSION} https://cdn.appscode.com/files/cluster-api-provider-${PROVIDER_NAME}/${INFRASTRUCTURE_VERSION}/infrastructure-components.yaml
    wget -P ${HOME}/assets/infrastructure-${PROVIDER_NAME}/${INFRASTRUCTURE_VERSION} https://cdn.appscode.com/files/cluster-api-provider-${PROVIDER_NAME}/${INFRASTRUCTURE_VERSION}/cluster-template-${SERVICE_NAME}.yaml
    wget -P ${HOME}/assets/infrastructure-${PROVIDER_NAME}/${INFRASTRUCTURE_VERSION} https://cdn.appscode.com/files/cluster-api-provider-${PROVIDER_NAME}/${INFRASTRUCTURE_VERSION}/metadata.yaml

    cat <<EOF >${HOME}/assets/config.yaml
providers:
  - name: "cluster-api"
    type: "CoreProvider"
    url: "${HOME}/assets/cluster-api/$CLUSTER_API_VERSION/core-components.yaml"
  - name: "kubeadm"
    type: "BootstrapProvider"
    url: "${HOME}/assets/bootstrap-kubeadm/$CLUSTER_API_VERSION/bootstrap-components.yaml"
  - name: "kubeadm"
    type: "ControlPlaneProvider"
    url: "${HOME}/assets/control-plane-kubeadm/$CLUSTER_API_VERSION/control-plane-components.yaml"
  - name: "${PROVIDER_NAME}"
    type: "InfrastructureProvider"
    url: "${HOME}/assets/infrastructure-${PROVIDER_NAME}/$INFRASTRUCTURE_VERSION/infrastructure-components.yaml"
overridesFolder: "${HOME}/assets"
EOF
}

#capi-config-linux-amd64 capz <./cluster.yaml >./configured-cluster.yaml
install_capi-config() {
    curl -fsSLO https://github.com/bytebuilders/capi-config/releases/download/v0.0.1/capi-config-linux-amd64.tar.gz
    tar -xzf capi-config-linux-amd64.tar.gz
    cp capi-config-linux-amd64 /bin
}

init() {
    install_wget
    install_helm
    install_kubectl
    install_clusterctl
    install_capi-config
    generate_infrastructure_config_files
}

init
