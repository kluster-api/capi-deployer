FROM alpine AS builder

LABEL org.opencontainers.image.source=https://github.com/kluster-api/capi-deployer

ARG TARGETOS
ARG TARGETARCH

ARG CLUSTERCTL="v1.10.4"
ARG CLUSTER_API_VERSION="v1.10.4"
ARG INFRASTRUCTURE_VERSION="v0.1.10"

RUN apk add --update --no-cache bash ca-certificates curl openssl unzip wget jq

COPY script.sh .

RUN chmod +x script.sh
RUN ./script.sh