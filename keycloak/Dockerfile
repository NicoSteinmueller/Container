FROM quay.io/keycloak/keycloak:26.7.2@sha256:831330513f55695572286e521f94fcd3c7e285250ed5b848090265a33192f669

ARG UID
ARG GID
USER root
RUN chown -R ${UID}:${GID} /opt/keycloak

USER ${UID}:${GID}