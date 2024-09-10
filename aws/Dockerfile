FROM ubuntu:latest

ARG TARGETOS
ARG TARGETARCH

LABEL org.opencontainers.image.source="https://github.com/kluster-api/capi-scripts"

ENV CLUSTERCTL="v1.6.3"
ENV CLUSTERAWSADM_VERSION="v2.4.2"
ENV INFRASTRUCTURE_VERSION="v2.4.2"
ENV CLUSTER_API_VERSION="v1.6.3"
ENV IAM_AUTHENTICATOR_VERSION="0.6.14"

RUN apt-get -y update; apt-get -y install curl

COPY script.sh .

RUN chmod +x script.sh
RUN ./script.sh