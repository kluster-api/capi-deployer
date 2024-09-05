FROM ubuntu:latest

ARG TARGETOS
ARG TARGETARCH

LABEL org.opencontainers.image.source="https://github.com/kluster-api/capi-scripts"

#for alpine
#RUN apk add --no-cache bash curl ca-certificates

#for ubuntu
RUN apt-get -y update; apt-get -y install curl

COPY script.sh .

RUN chmod +x script.sh
RUN ./script.sh