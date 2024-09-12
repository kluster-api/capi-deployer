FROM alpine AS builder

LABEL org.opencontainers.image.source=https://github.com/kluster-api/capi-deployer

ARG TARGETOS
ARG TARGETARCH

ARG CLUSTERCTL="v1.6.3"
ARG CLUSTERAWSADM_VERSION="v2.4.2"
ARG INFRASTRUCTURE_VERSION="v2.4.2"
ARG CLUSTER_API_VERSION="v1.6.3"
ARG IAM_AUTHENTICATOR_VERSION="0.6.14"

RUN apk add --update --no-cache bash ca-certificates curl openssl unzip wget

COPY script.sh .

RUN chmod +x script.sh
RUN ./script.sh
