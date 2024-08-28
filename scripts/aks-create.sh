#!/bin/bash

sudo su
HOME="/root"
cd ${HOME}

set -eou pipefail

export AZURE_SUBSCRIPTION_ID=" {{ .azure_subscription_id }}"
export AZURE_TENANT_ID="{{ .azure_tenant_id }}"
export AZURE_CLIENT_ID="{{ .azure_client_id }}"
export AZURE_CLIENT_SECRET="{{ .azure_client_secret }}"
export CLUSTER="{{ .cluster }}"
export WORKER_MACHINE_COUNT={{ .worker_machine_count }}
export AZURE_NODE_MACHINE_TYPE="{{ .azure_node_machine_type }}"
export KUBERNETES_VERSION="v{{ .kubernetes_version }}"
export AZURE_LOCATION="{{ .azure_location }}"
export VNET_CIDR="{{ .vnet_cidr }}"

# for logs...
export NATS_CREDS="{{ .nats_creds }}"
export NATS_SERVER="{{ .nats_server }}"
export SHIPPER_SUBJECT="{{ .shipper_subject }}"

export EXP_MACHINE_POOL=true
export EXP_AKS=true
export CLUSTER_TOPOLOGY=true

rollback() {
    kubectl delete cluster $CLUSTER_NAME -n ${CLUSTER_NAMESPACE}
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

curl -fsSLO https://github.com/bytebuilders/nats-logger/releases/latest/download/nats-logger-linux-amd64.tar.gz
tar -xzvf nats-logger-linux-amd64.tar.gz
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

PROVIDER_NAME=azure
SERVICE_NAME=aks

export CLUSTER_NAME=${CLUSTER}
export CLUSTER_IDENTITY_NAME=${CLUSTER_NAME}
export AZURE_CLUSTER_IDENTITY_SECRET_NAME="${CLUSTER_NAME}-secret"
export AZURE_CLUSTER_IDENTITY_SECRET_NAMESPACE=${CLUSTER_NAMESPACE}
export SUBNET_CIDR=${VNET_CIDR}

KIND_KUBECONFIG="${HOME}/.kube/config"
AZURE_KUBECONFIG="${HOME}/cluster.kubeconfig"

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

wait_for_docker() {
    while [[ -z "$(! docker stats --no-stream 2>/dev/null)" ]]; do
        echo "Waiting for docker to start"
        sleep 30s
    done
}

install_kind() {
    echo "--------------creating kind--------------"

    local cmnd="curl -Lo ./kind https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${sys_arch}"
    retry 5 ${cmnd}

    chmod +x ./kind

    cmnd="mv ./kind /usr/local/bin/kind"
    retry 5 ${cmnd}
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

create_kind_cluster() {
    cmnd="kind delete cluster"
    retry 5 ${cmnd}

    sleep 5s

    kind create cluster --image=kindest/node:${KIND_IMAGE_VERSION}
    kubectl wait --for=condition=ready pods --all -A --timeout=5m
}

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
    mkdir -p /root/assets/infrastructure-${PROVIDER_NAME}/${INFRASTRUCTURE_VERSION} /root/assets/bootstrap-kubeadm/${CLUSTER_API_VERSION} /root/assets/cluster-api/${CLUSTER_API_VERSION} /root/assets/control-plane-kubeadm/${CLUSTER_API_VERSION}

    wget -P /root/assets/cluster-api/${CLUSTER_API_VERSION} https://cdn.appscode.com/files/cluster-api/${CLUSTER_API_VERSION}/core-components.yaml
    wget -P /root/assets/cluster-api/${CLUSTER_API_VERSION} https://cdn.appscode.com/files/cluster-api/${CLUSTER_API_VERSION}/metadata.yaml
    wget -P /root/assets/bootstrap-kubeadm/${CLUSTER_API_VERSION} https://cdn.appscode.com/files/cluster-api/${CLUSTER_API_VERSION}/bootstrap-components.yaml
    wget -P /root/assets/bootstrap-kubeadm/${CLUSTER_API_VERSION} https://cdn.appscode.com/files/cluster-api/${CLUSTER_API_VERSION}/metadata.yaml
    wget -P /root/assets/control-plane-kubeadm/${CLUSTER_API_VERSION} https://cdn.appscode.com/files/cluster-api/${CLUSTER_API_VERSION}/control-plane-components.yaml
    wget -P /root/assets/control-plane-kubeadm/${CLUSTER_API_VERSION} https://cdn.appscode.com/files/cluster-api/${CLUSTER_API_VERSION}/metadata.yaml
    wget -P /root/assets/infrastructure-${PROVIDER_NAME}/${INFRASTRUCTURE_VERSION} https://cdn.appscode.com/files/cluster-api-provider-${PROVIDER_NAME}/${INFRASTRUCTURE_VERSION}/infrastructure-components.yaml
    wget -P /root/assets/infrastructure-${PROVIDER_NAME}/${INFRASTRUCTURE_VERSION} https://cdn.appscode.com/files/cluster-api-provider-${PROVIDER_NAME}/${INFRASTRUCTURE_VERSION}/cluster-template-${SERVICE_NAME}.yaml
    wget -P /root/assets/infrastructure-${PROVIDER_NAME}/${INFRASTRUCTURE_VERSION} https://cdn.appscode.com/files/cluster-api-provider-${PROVIDER_NAME}/${INFRASTRUCTURE_VERSION}/metadata.yaml

    cat <<EOF >/root/assets/config.yaml
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

    install_cert_manager "${kubeconfig}"

    echo "init azure cluster"
    cmnd="clusterctl init --infrastructure ${PROVIDER_NAME}"
    retry 5 ${cmnd} --config=/root/assets/config.yaml --kubeconfig=${kubeconfig}

    echo "waiting for capi pods to be ready..."
    kubectl wait --for=condition=ready pods --all -n capz-system --timeout=10m --kubeconfig=${kubeconfig}
    kubectl wait --for=condition=ready pods --all -n capi-kubeadm-bootstrap-system --timeout=10m --kubeconfig=${kubeconfig}
    kubectl wait --for=condition=ready pods --all -n capi-kubeadm-control-plane-system --timeout=10m --kubeconfig=${kubeconfig}
    kubectl wait --for=condition=ready pods --all -n capi-system --timeout=10m --kubeconfig=${kubeconfig}
}

generate_identity_secret() {
    echo "--------Generating identity secret ${AZURE_CLUSTER_IDENTITY_SECRET_NAME}------------"
    kubectl create ns $CLUSTER_NAMESPACE

    local cmnd="kubectl create secret generic"
    retry 5 ${cmnd} "${AZURE_CLUSTER_IDENTITY_SECRET_NAME}" --from-literal=clientSecret="${AZURE_CLIENT_SECRET}" --namespace "${AZURE_CLUSTER_IDENTITY_SECRET_NAMESPACE}"
}

configure_yaml() {
    curl -fsSLO https://github.com/bytebuilders/capi-config/releases/download/v0.0.1/capi-config-linux-amd64.tar.gz
    tar -xzf capi-config-linux-amd64.tar.gz
    cp capi-config-linux-amd64 /bin
    capi-config-linux-amd64 capz <./cluster.yaml >./configured-cluster.yaml
}

create_aks_cluster() {
    cmnd="clusterctl generate cluster"
    retry 5 ${cmnd} ${CLUSTER_NAME} --flavor ${SERVICE_NAME} --kubernetes-version ${KUBERNETES_VERSION} --worker-machine-count=${WORKER_MACHINE_COUNT} -n ${CLUSTER_NAMESPACE} --config=/root/assets/config.yaml >cluster.yaml

    kubectl apply -f cluster.yaml -n ${CLUSTER_NAMESPACE}

    echo "creating cluster..."
    kubectl wait --for=condition=ready cluster --all -A --timeout=30m
    echo "----------${CLUSTER_NAME} is created successfully-------------"
}

generate_kubeconfig() {
    echo "-------------generating kubeconfig-----------"
    local cmnd="clusterctl get kubeconfig"
    retry 5 ${cmnd} ${CLUSTER_NAME} -n ${CLUSTER_NAMESPACE} >$HOME/cluster.kubeconfig
}

move_cluster() {
    echo "pivoting azure cluster..."
    clusterctl move --to-kubeconfig=$AZURE_KUBECONFIG -n $CLUSTER_NAMESPACE
}

pivot_azure_cluster() {
    export KUBECONFIG=${AZURE_KUBECONFIG}
    init_infrastructure ${AZURE_KUBECONFIG}
    generate_identity_secret

    export KUBECONFIG=$KIND_KUBECONFIG
    move_cluster
}

create_credential_secret() {
    export KUBECONFIG=${AZURE_KUBECONFIG}

    cat <<EOF | kubectl apply -f -
  apiVersion: v1
  kind: Secret
  metadata:
    name: azure-credential
    namespace: ${CLUSTER_NAMESPACE}
  type: Opaque
  stringData:
    credential_json: |
      {
        "clientId": ${AZURE_CLIENT_ID},
        "clientSecret": ${AZURE_CLIENT_SECRET},
        "subscriptionId": ${AZURE_SUBSCRIPTION_ID},
        "tenantId": ${AZURE_TENANT_ID}
      }
EOF
}

init() {
    wait_for_docker

    install_helm
    install_kind
    install_kubectl

    sleep 60s

    create_kind_cluster
    install_clusterctl
    generate_infrastructure_config_files
    init_infrastructure "${KIND_KUBECONFIG}"
    generate_identity_secret
    create_aks_cluster
    generate_kubeconfig

    pivot_azure_cluster
    create_credential_secret
}

init
