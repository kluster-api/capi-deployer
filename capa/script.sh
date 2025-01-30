#!/bin/bash
set -xeo pipefail
HOME="/home"

PROVIDER_NAME=aws
SERVICE_NAME=eks-managedmachinepool

export CONTROLPLANE_ROLE="controlplane"-$CLUSTER_NAME-$CLUSTER_NAMESPACE-${SUFFIX}

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

install_nats-logger() {
    curl -fsSLO https://github.com/appscode-cloud/nats-logger/releases/download/v0.0.6/nats-logger-linux-amd64.tar.gz
    tar -xzvf nats-logger-linux-amd64.tar.gz
    chmod +x nats-logger-linux-amd64
    mv nats-logger-linux-amd64 /bin/nats-logger
}

install_capi-config() {
    curl -fsSLO https://github.com/bytebuilders/capi-config/releases/download/v0.0.1/capi-config-linux-amd64.tar.gz
    tar -xzf capi-config-linux-amd64.tar.gz
    cp capi-config-linux-amd64 /bin
}

install_kubectl() {
    ltral="https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/${opsys}/${sys_arch}/kubectl"
    local cmnd="curl -LO"
    retry 5 ${cmnd} ${ltral}
    ltral="https://dl.k8s.io/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/${opsys}/${sys_arch}/kubectl.sha256"
    cmnd="curl -LO"
    retry 5 ${cmnd} ${ltral}
    echo "$(cat kubectl.sha256)  kubectl" | sha256sum -c
    cmnd="install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl"
    retry 5 ${cmnd}
}

install_helm() {
    local cmnd="curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3"
    retry 5 ${cmnd}
    chmod 700 get_helm.sh
    cmnd="./get_helm.sh"
    retry 5 ${cmnd}
}

install_clusterctl() {
    local cmnd="curl -L https://github.com/kubernetes-sigs/cluster-api/releases/download/${CLUSTER_API_VERSION}/clusterctl-${opsys}-${sys_arch} -o clusterctl"
    retry 5 ${cmnd}
    cmnd="install -o root -g root -m 0755 clusterctl /usr/local/bin/clusterctl"
    retry 5 ${cmnd}
    clusterctl version
}

install_clusterawsadm() {
    local cmnd="curl -L https://github.com/kubernetes-sigs/cluster-api-provider-aws/releases/download/${INFRASTRUCTURE_VERSION}/clusterawsadm-${opsys}-${sys_arch} -o clusterawsadm"
    retry 5 ${cmnd}
    chmod +x clusterawsadm
    mv clusterawsadm /usr/local/bin
    clusterawsadm version
}


install_aws_iam_authenticator() {
    local cmnd="curl -Lo aws-iam-authenticator https://github.com/kubernetes-sigs/aws-iam-authenticator/releases/download/v${IAM_AUTHENTICATOR_VERSION}/aws-iam-authenticator_${IAM_AUTHENTICATOR_VERSION}_${opsys}_${sys_arch}"
    retry 5 ${cmnd}
    chmod +x aws-iam-authenticator
    mv aws-iam-authenticator /usr/local/bin
}

generate_infrastructure_config_files() {
    # folder structure: {basepath}/{provider-name}/{version}/{components.yaml}
    mkdir -p ${HOME}/assets/infrastructure-${PROVIDER_NAME}/${INFRASTRUCTURE_VERSION} ${HOME}/assets/bootstrap-kubeadm/${CLUSTER_API_VERSION} ${HOME}/assets/cluster-api/${CLUSTER_API_VERSION} ${HOME}/assets/control-plane-kubeadm/${CLUSTER_API_VERSION}

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

install_aws_cli() {
    apk add --update --no-cache aws-cli
}

install_eksctl() {
    # for ARM systems, set ARCH to: `arm64`, `armv6` or `armv7`
    ARCH=amd64
    PLATFORM=$(uname -s)_$ARCH
    curl -sLO "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_$PLATFORM.tar.gz"
    # (Optional) Verify checksum
    curl -sL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_checksums.txt" | grep $PLATFORM | sha256sum -c
    tar -xzf eksctl_$PLATFORM.tar.gz -C /tmp && rm eksctl_$PLATFORM.tar.gz
    mv /tmp/eksctl /usr/local/bin
}

init() {
    install_nats-logger
    install_capi-config
    install_kubectl
    install_helm
    install_clusterctl
    install_clusterawsadm
    install_aws_cli
    install_eksctl
    install_aws_iam_authenticator
    generate_infrastructure_config_files
}
init
