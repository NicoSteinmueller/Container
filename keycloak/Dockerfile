FROM quay.io/keycloak/keycloak:26.6.2@sha256:5afd40414096432903a5374ba4ba70b931dcca598a6bd9f44239fe66ef8d9737

USER root

RUN mkdir -p /opt/keycloak/data/tmp \
    && chown -R 99:100 /opt/keycloak

USER 99:100