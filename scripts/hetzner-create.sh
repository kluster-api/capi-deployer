#!/bin/bash
HOME="/root"
cd ${HOME}
apt-get -y update

set -xeo pipefail
export HCLOUD_SSH_KEY="parvejSSH"
export CLUSTER_NAME="parvej"
export HCLOUD_REGION="fsn1"
export CONTROL_PLANE_MACHINE_COUNT=1
export WORKER_MACHINE_COUNT={{ .worker_machine_count }}
export KUBERNETES_VERSION="{{.kubernetes_version}}"
export HCLOUD_CONTROL_PLANE_MACHINE_TYPE="{{.mchine_type}}"
export HCLOUD_WORKER_MACHINE_TYPE=cpx31
export HCLOUD_TOKEN="{{.hcloud_token}}"

export NATS_CREDS="{{ .nats_creds }}"
export NATS_SERVER="{{ .nats_server }}"
export SHIPPER_SUBJECT="{{ .shipper_subject }}"
export SUFFIX="{{ .random_suffix }}"

exec >/root/create-script.log 2>&1

CLUSTERCTL_VERSION="{{ .clusterctl_version }}"
VCLUSTER_VERSION="v0.20.0-beta.9"
VCLUSTER_NAME="{{.vcluster_name}}"
VCLUSTER_NAMESPACE="{{.vcluster_namespace}}"

CLUSTER_NAME="{{.cluster_name}}"
CLUSTER_NAMESPACE="{{.cluster_name}}"

rollback() {
    # kubectl delete cluster $CLUSTER_NAME -n ${CLUSTER_NAMESPACE} --kubeconfig=${VCLUSTER_KUBECONFIG}

    # kubectl delete ns ${VCLUSTER_NAMESPACE}
    echo "hi"
}
function finish() {
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
SHIPPER_FILE=/root/create-script.log ./nats-logger &

PROVIDER_NAME=hetzner

HETZNER_KUBECONFIG=""

VCLUSTER_KUBECONFIG=""

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

install_kubectl() {
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
    local cmnd="curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3"
    retry 5 ${cmnd}
    chmod 700 get_helm.sh
    cmnd="./get_helm.sh"
    retry 5 ${cmnd}
}

install_clusterctl() {
    local cmnd="curl -L https://github.com/kubernetes-sigs/cluster-api/releases/download/${CLUSTERCTL_VERSION}/clusterctl-${opsys}-${sys_arch} -o clusterctl"
    retry 5 ${cmnd}
    cmnd="install -o root -g root -m 0755 clusterctl /usr/local/bin/clusterctl"
    retry 5 ${cmnd}
    clusterctl version
}

install_vclusterCLI() {

    local cmnd="curl -L -o vcluster https://github.com/loft-sh/vcluster/releases/download/${VCLUSTER_VERSION}/vcluster-${opsys}-${sys_arch}"
    retry 5 ${cmnd}
    install -c -m 0755 vcluster /usr/local/bin
    rm -f vcluster

}

create_vcluster() {
    local cmnd="vcluster create ${VCLUSTER_NAME} --namespace ${VCLUSTER_NAMESPACE} --connect=false"
    retry 5 ${cmnd}
    kubectl wait --for=condition=ready pods --all -n ${VCLUSTER_NAMESPACE} --timeout=5m
}
generate_vcluster_kubeconfig() {
    local cmnd="vcluster connect ${VCLUSTER_NAME} -n ${VCLUSTER_NAMESPACE} --server=${VCLUSTER_NAME}.${VCLUSTER_NAMESPACE} --insecure --update-current=false"
    retry 5 ${cmnd}
    cat kubeconfig.yaml >${VCLUSTER_NAME}-kubeconfig.yaml

    export VCLUSTER_KUBECONFIG=${VCLUSTER_NAME}-kubeconfig.yaml

    #export KUBECONFIG=${VCLUSTER_NAME}-kubeconfig.yaml
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

    echo "init hetzner cluster"
    cmnd="clusterctl init --infrastructure ${PROVIDER_NAME}"
    retry 5 ${cmnd} --kubeconfig=${kubeconfig}
    echo "waiting for capi pods to be ready..."
    kubectl wait --for=condition=ready pods --all -A --timeout=15m --kubeconfig=${kubeconfig}

}

create_secret_for_hetzner() {
    kubectl create secret generic hetzner --from-literal=hcloud=$HCLOUD_TOKEN --kubeconfig=${VCLUSTER_KUBECONFIG} --namespace=${CLUSTER_NAMESPACE}
    kubectl patch secret hetzner -p '{"metadata":{"labels":{"clusterctl.cluster.x-k8s.io/move":""}}}' --kubeconfig=${VCLUSTER_KUBECONFIG} --namespace=${CLUSTER_NAMESPACE}
}

create_hetzner_cluster() {
    create_secret_for_hetzner
    local cmnd="clusterctl generate cluster"
    retry 5 ${cmnd} ${CLUSTER_NAME} --kubernetes-version ${KUBERNETES_VERSION} --control-plane-machine-count=${CONTROL_PLANE_MACHINE_COUNT} --worker-machine-count=${WORKER_MACHINE_COUNT} -n ${CLUSTER_NAMESPACE} --kubeconfig=${VCLUSTER_KUBECONFIG} >cluster.yaml
    kubectl apply -f cluster.yaml --kubeconfig=${VCLUSTER_KUBECONFIG}

    echo "creating cluster..."
    kubectl wait --for=condition=ready cluster --all -A --timeout=30m --kubeconfig=${VCLUSTER_KUBECONFIG}
    echo "----------${CLUSTER_NAME} is created successfully-------------"
}

generate_kubeconfig() {
    echo "-------------generating kubeconfig-----------"
    local cmnd="clusterctl get kubeconfig"
    retry 5 ${cmnd} ${CLUSTER_NAME} -n ${CLUSTER_NAMESPACE} --kubeconfig=${VCLUSTER_KUBECONFIG} >$HOME/cluster.kubeconfig
    export HETZNER_KUBECONFIG=$HOME/cluster.kubeconfig
}

install_CNI_CCM() {
    echo "installing CNI"
    export KUBECONFIG=$HETZNER_KUBECONFIG
    helm repo add cilium https://helm.cilium.io/
    helm repo update cilium

    curl "https://raw.githubusercontent.com/syself/cluster-api-provider-hetzner/main/templates/cilium/cilium.yaml" -o cilium.yaml

    helm upgrade --install cilium cilium/cilium --version 1.14.4 \
        --namespace kube-system \
        -f cilium.yaml

    #CCM

    echo "installing CCM"
    helm repo add syself https://charts.syself.com
    helm repo update syself
    helm upgrade --install ccm syself/ccm-hcloud --version 1.0.11 \
        --namespace kube-system \
        --set secret.name=hetzner \
        --set secret.tokenKeyName=hcloud \
        --set privateNetwork.enabled=false

    kubectl wait --for=condition=ready pods --all -A --timeout=15m
    echo "Successfully installed CNI and CCM"
    export KUBECONFIG=$VCLUSTER_KUBECONFIG

}

move_cluster() {
    echo "pivoting azure cluster..."
    clusterctl move --to-kubeconfig=$HETZNER_KUBECONFIG -n $CLUSTER_NAMESPACE
}

pivot_hetzner_cluster() {
    export KUBECONFIG=${HETZNER_KUBECONFIG}
    init_infrastructure ${HETZNER_KUBECONFIG}

    export KUBECONFIG=$VCLUSTER_KUBECONFIG
    move_cluster
}
create_credential_secret() {
    export KUBECONFIG=${HETZNER_KUBECONFIG}

    cat <<EOF | kubectl apply -f -
  apiVersion: v1
  kind: Secret
  metadata:
    name: hetzner-credential
    namespace: ${CLUSTER_NAMESPACE}
  type: Opaque
  stringData:
    credential_json: |
      {
        "hetznerToken":${HCLOUD_TOKEN}
        "sshName":{{ .hetzner_ssh_key_name }}
      }
EOF

}
delete_vcluster() {
    vcluster delete ${VCLUSTER_NAME} -n ${VCLUSTER_NAMESPACE}
}

init() {
    install_kubectl
    install_helm

    sleep 3s
    install_clusterctl

    install_vclusterCLI
    create_vcluster
    generate_vcluster_kubeconfig
    echo ${VCLUSTER_KUBECONFIG}
    kubectl create ns ${CLUSTER_NAMESPACE} --kubeconfig=${VCLUSTER_KUBECONFIG}

    init_infrastructure "${VCLUSTER_KUBECONFIG}"

    create_hetzner_cluster
    generate_kubeconfig
    install_CNI_CCM

    pivot_hetzner_cluster
    create_credential_secret
}
init
