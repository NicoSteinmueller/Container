FROM alpine:3.24@sha256:e7c4abb69531cb09e2a2bbb56fad3367ab694865c49df898c1c683185cc4376c

RUN apk add --no-cache logrotate

COPY access.logrotate /etc/logrotate.d/access.logrotate

