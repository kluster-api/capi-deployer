FROM ubuntu:latest

ARG TARGETOS
ARG TARGETARCH

LABEL org.opencontainers.image.source="https://github.com/kluster-api/capi-scripts"

ENV CLUSTERCTL="v1.6.3"
ENV INFRASTRUCTURE_VERSION="v1.6.0"
ENV CLUSTER_API_VERSION="v1.6.3"
ENV YQ_VERSION="v4.2.0"

RUN apt-get -y update; apt-get -y install curl

COPY script.sh .

RUN chmod +x script.sh
RUN ./script.sh