FROM quay.io/keycloak/keycloak:26.7.0@sha256:2eb3cd316835c990e69e26ade292ffa78f6fb0db7d5fc6377463c162e1979ac0

ARG UID
ARG GID
USER root
RUN chown -R ${UID}:${GID} /opt/keycloak

USER ${UID}:${GID}