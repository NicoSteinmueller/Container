FROM quay.io/keycloak/keycloak:26.8.1@sha256:79c623a22abacf3fe6c00a5fb30f5b7843d717b234033b80995891c06116d244

ARG UID
ARG GID
USER root
RUN chown -R ${UID}:${GID} /opt/keycloak

USER ${UID}:${GID}