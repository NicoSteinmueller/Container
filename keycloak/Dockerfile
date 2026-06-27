FROM quay.io/keycloak/keycloak:26.6.4@sha256:20e96e40e673ffa474ac4da56c91cb0adba28b8571bd274ce255e6120265c1f4

ARG UID
ARG GID
USER root
RUN chown -R ${UID}:${GID} /opt/keycloak

USER ${UID}:${GID}