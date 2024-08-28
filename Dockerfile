FROM alpine

ARG TARGETOS
ARG TARGETARCH

LABEL org.opencontainers.image.source https://github.com/kluster-api/capi-scripts

RUN apk add --no-cache bash curl ca-certificates

COPY scripts /tmp/scripts
