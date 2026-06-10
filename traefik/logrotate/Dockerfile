FROM alpine:3.24@sha256:8ddefa941e689fc29abcdeb8dae3b3c6d139cc08ce9a52633931160701770685

RUN apk add --no-cache logrotate

COPY access.logrotate /etc/logrotate.d/access.logrotate

