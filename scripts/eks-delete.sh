#!/bin/bash

sudo su
HOME="/root"
cd ${HOME}

apt-get -y update
sleep 30s

set -eou pipefail

export AWS_ACCESS_KEY_ID="{{ .aws_access_key_id }}"
export AWS_SECRET_ACCESS_KEY="{{ .aws_secret_access_key }}"
export AWS_REGION="{{ .aws_region }}"
export B64ENCODED_REMOTE_KUBECONFIG="{{ .b64encoded_remote_kubeconfig }}"

export NATS_CREDS="{{ .nats_creds }}"
export NATS_SERVER="{{ .nats_server }}"
export SHIPPER_SUBJECT="{{ .shipper_subject }}"

exec >/root/delete-script.log 2>&1

rollback() {
    kubectl delete cluster $CLUSTER_NAME -n $CLUSTER_NAMESPACE || true
    delete_cloudformation_stack
    delete_roles
}

function finish {
    result=$?
    if [ $result -ne 0 ]; then
        rollback || true
    fi

    if [ $result -ne 0 ]; then
        echo "Cluster deletion: Task failed !"
    else
        echo "Cluster deletion: Task completed successfully !"
    fi

    sleep 5s

    [ ! -f /tmp/result.txt ] && echo $result >/tmp/result.txt
}
trap finish EXIT

curl -fsSLO https://github.com/bytebuilders/nats-logger/releases/latest/download/nats-logger-linux-amd64.tar.gz
tar -xzvf nats-logger-linux-amd64.tar.gz
chmod +x nats-logger-linux-amd64
mv nats-logger-linux-amd64 nats-logger

SHIPPER_FILE=/root/delete-script.log ./nats-logger &

KIND_VERSION="{{ .kind_version }}"
KIND_IMAGE_VERSION="{{ .kind_image_version }}"
CLUSTERCTL_VERSION="{{ .clusterctl_version }}"
CLUSTERAWSADM_VERSION="{{ .clusterawsadm_version }}"
IAM_AUTHENTICATOR_VERSION="{{ .iam_authenticator_version }}"
CLUSTER_NAMESPACE=capi-cluster

# for generating infrastructure component
CLUSTER_API_VERSION="{{ .cluster_api_version }}"
INFRASTRUCTURE_VERSION="{{ .infrastructure_version }}"

PROVIDER_NAME=aws
SERVICE_NAME=eks-managedmachinepool

#for IRSA
#EKS_CLUSTER_NAME=$CLUSTER_NAMESPACE"_"$CLUSTER_NAME"-control-plane"
EDNS_SA="external-dns-operator"
EDNS_NS="kubeops"

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
    local msg\="$2"
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
    echo $B64ENCODED_REMOTE_KUBECONFIG | base64 --decode >/root/kubeconfig
}

install_docker_apt() {
    while [[ -z "$(! docker stats --no-stream 2>/dev/null)" ]]; do
        echo "Waiting for docker to start"
        sleep 30s
    done

    for pkg in docker.io docker-doc docker-compose podman-docker containerd containerd.io runc; do sudo apt-get -y remove $pkg || true; done
    apt-get -y autoremove
    apt-get update
    apt -y install docker.io
}
install_yq() {
    snap install yq
}

install_kind() {
    echo "--------------creating kind--------------"

    local cmnd="curl -Lo ./kind https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${sys_arch}"
    retry 5 ${cmnd}

    chmod +x ./kind

    cmnd="mv ./kind /usr/local/bin/kind"
    retry 5 ${cmnd}
}

create_kind_cluster() {
    cmnd="kind delete cluster"
    retry 5 ${cmnd}

    sleep 5s

    kind create cluster --image=kindest/node:${KIND_IMAGE_VERSION}
    kubectl wait --for=condition=ready pods --all -A --timeout=5m
}

install_kubectl() {
    LTRAL="https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/${opsys}/${sys_arch}/kubectl"
    local cmnd="curl -LO"
    retry 5 ${cmnd} ${LTRAL}

    LTRAL="https://dl.k8s.io/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/${opsys}/${sys_arch}/kubectl.sha256"
    cmnd="curl -LO"
    retry 5 ${cmnd} ${LTRAL}

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

install_clusterawsadm() {
    local cmnd="curl -L https://github.com/kubernetes-sigs/cluster-api-provider-aws/releases/download/${CLUSTERAWSADM_VERSION}/clusterawsadm_${CLUSTERAWSADM_VERSION}_${opsys}_${sys_arch} -o clusterawsadm"
    retry 5 ${cmnd}

    chmod +x clusterawsadm
    mv clusterawsadm /usr/local/bin
    clusterawsadm version
}

install_aws_cli() {
    apt install unzip >/dev/null
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" >/dev/null
    unzip awscliv2.zip >/dev/null
    sudo ./aws/install >/dev/null
}

install_aws_iam_authenticator() {
    local cmnd="curl -Lo aws-iam-authenticator https://github.com/kubernetes-sigs/aws-iam-authenticator/releases/download/v${IAM_AUTHENTICATOR_VERSION}/aws-iam-authenticator_${IAM_AUTHENTICATOR_VERSION}_${opsys}_${sys_arch}"

    retry 5 ${cmnd}
    chmod +x ./aws-iam-authenticator
    mkdir -p $HOME/bin && cp ./aws-iam-authenticator $HOME/bin/aws-iam-authenticator && export PATH=$PATH:$HOME/bin
    echo 'export PATH=$PATH:$HOME/bin' >>~/.bashrc
    aws-iam-authenticator help
}

generate_infrastructure_config_files() {

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

    kubectl wait --for=condition=ready pods --all -n cert-manager --timeout=10m --kubeconfig=${kubeconfig}
}

init_infrastructure() {
    local kubeconfig="$1"
    echo "-----------initializing infrastructure ${PROVIDER_NAME}--------------"

    install_cert_manager "${kubeconfig}"

    cmnd="clusterctl init --infrastructure ${PROVIDER_NAME}"
    retry 5 ${cmnd} --config=/root/assets/config.yaml --kubeconfig=${kubeconfig}

    kubectl wait --for=condition=ready pods --all -n capa-system --timeout=10m --kubeconfig=${kubeconfig}
    kubectl wait --for=condition=ready pods --all -n capi-kubeadm-bootstrap-system --timeout=10m --kubeconfig=${kubeconfig}
    kubectl wait --for=condition=ready pods --all -n capi-kubeadm-control-plane-system --timeout=10m --kubeconfig=${kubeconfig}
    kubectl wait --for=condition=ready pods --all -n capi-system --timeout=10m --kubeconfig=${kubeconfig}
}

init_aws_infrastructure() {
    export AWS_B64ENCODED_CREDENTIALS=$(clusterawsadm bootstrap credentials encode-as-profile)
    export EXP_MACHINE_POOL=true

    generate_infrastructure_config_files
    init_infrastructure "${HOME}/.kube/config"
}

get_cluster_name() {
    CLUSTER_NAME=$(kubectl get cluster -A --kubeconfig=${HOME}/kubeconfig | grep $CLUSTER_NAMESPACE | awk '{print $2}')
}

delete_roles() {
    CONTROLPLANE_ROLE="controlplane"-$CLUSTER_NAME-$CLUSTER_NAMESPACE-${SUFFIX}
    aws iam detach-role-policy --role-name ${CONTROLPLANE_ROLE} --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy || true
    aws iam delete-role --role-name ${CONTROLPLANE_ROLE} || true

}

pivot_cluster() {
    clusterctl move --to-kubeconfig=${HOME}/.kube/config --kubeconfig=${HOME}/kubeconfig -n $CLUSTER_NAMESPACE
    sleep 1m
    SUFFIX=$(kubectl get cluster -n ${CLUSTER_NAMESPACE} ${CLUSTER_NAME} -o jsonpath='{.metadata.annotations.appscode/eks-iam-suffix}' || true)
}

delete_cluster() {
    kubectl delete cluster $CLUSTER_NAME -n $CLUSTER_NAMESPACE --kubeconfig=${HOME}/.kube/config
}

delete_cloudformation_stack() {
    cat >bootstrap-config.yaml <<EOF
        apiVersion: bootstrap.aws.infrastructure.cluster.x-k8s.io/v1beta1
        kind: AWSIAMConfiguration
        spec:
          stackName: $CLUSTER_NAME-$CLUSTER_NAMESPACE-${SUFFIX}
          nameSuffix: $CLUSTER_NAME-$CLUSTER_NAMESPACE-${SUFFIX}
          eks:
            iamRoleCreation: true
            managedMachinePool:
              disable: true
            fargate:
              disable: true
EOF
    clusterawsadm bootstrap iam delete-cloudformation-stack --config bootstrap-config.yaml || true
}

init() {
    set_kubeconfig
    install_docker_apt
    install_kind
    install_kubectl

    sleep 1m

    install_helm
    create_kind_cluster
    install_clusterctl
    install_clusterawsadm
    install_aws_cli
    install_aws_iam_authenticator
    init_aws_infrastructure

    get_cluster_name

    pivot_cluster
    delete_cluster
    delete_cloudformation_stack
    delete_roles
}
init
