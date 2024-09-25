FROM alpine AS builder

LABEL org.opencontainers.image.source=https://github.com/kluster-api/capi-deployer

ARG TARGETOS
ARG TARGETARCH

ARG CLUSTERCTL="v1.7.4"
ARG CLUSTERAWSADM_VERSION="v2.6.1"
ARG INFRASTRUCTURE_VERSION="v2.6.1"
ARG CLUSTER_API_VERSION="v1.7.4"
ARG IAM_AUTHENTICATOR_VERSION="0.6.23"

RUN apk add --update --no-cache bash ca-certificates curl openssl unzip wget yq

COPY script.sh .

RUN chmod +x script.sh
RUN ./script.sh
