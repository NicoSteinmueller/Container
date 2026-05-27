FROM quay.io/keycloak/keycloak:26.6.2@sha256:5afd40414096432903a5374ba4ba70b931dcca598a6bd9f44239fe66ef8d9737

ARG UID
ARG GID
USER root
RUN chown -R ${UID}:${GID} /opt/keycloak

USER ${UID}:${GID}