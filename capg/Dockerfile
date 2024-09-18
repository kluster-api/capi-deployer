FROM alpine AS builder

LABEL org.opencontainers.image.source=https://github.com/kluster-api/capi-deployer

ARG TARGETOS
ARG TARGETARCH

ARG CLUSTERCTL="v1.7.3"
ARG INFRASTRUCTURE_VERSION="v1.7.0"
ARG CLUSTER_API_VERSION="v1.7.3"
ARG YQ_VERSION="v4.2.0"

RUN apk add --update --no-cache bash ca-certificates curl openssl unzip wget jq  python3 py3-crcmod gnupg libc6-compat

COPY script.sh .

ENV PATH=$PATH:/usr/local/gcloud/google-cloud-sdk/bin

RUN chmod +x script.sh
RUN ./script.sh
