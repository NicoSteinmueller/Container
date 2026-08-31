FROM quay.io/keycloak/keycloak:26.7.3@sha256:ff4257d0d64efbe99ed1ddfaf07765cc3c36dc7518bf8324d41961327f441c54

ARG UID
ARG GID
USER root
RUN chown -R ${UID}:${GID} /opt/keycloak

USER ${UID}:${GID}