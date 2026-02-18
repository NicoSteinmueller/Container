- Fail2Ban
- Rate Limiting
- CrowdSec
- etc..

Adguard umstellen auf traefik als reverse proxy


https://doc.traefik.io/traefik/reference/routing-configuration/dynamic-configuration-methods/
https://www.simplehomelab.com/udms-18-traefik-docker-compose-guide/
https://goneuland.de/traefik-ab-v3-6-mit-crowdsec-installieren-und-konfigurieren/8/#7_Stack_konfigurieren
https://doc.traefik.io/traefik/reference/install-configuration/observability/metrics/
https://doc.traefik.io/traefik/reference/install-configuration/configuration-options/


# Config TODO
- metrics
- plugins

- Admin Pfad der Container nur lokal erreichbar machen

- Dashboard mit Authentifizierung absichern

- zwei Configs
  - Statische Config
    - Restart Notwendig
    - Entrypoints
    - Providers
    - API/Dashboard
    - Logging
  - Dynamische Config
    - Kein Restart Notwendig
    - Routers
    - Services
    - Middlewares


    labels:
      # Traefik aktivieren
      - "traefik.enable=true"

      # HTTP -> HTTPS Redirect
      - "traefik.http.routers.nextcloud-http.entrypoints=web"
      - "traefik.http.routers.nextcloud-http.rule=Host(`nextcloud.deinedomain.de`)" # TODO: Domain anpassen
      - "traefik.http.routers.nextcloud-http.middlewares=nextcloud-redirect"
      - "traefik.http.middlewares.nextcloud-redirect.redirectscheme.scheme=https"
      - "traefik.http.middlewares.nextcloud-redirect.redirectscheme.permanent=true"

      # HTTPS Router
      - "traefik.http.routers.nextcloud.entrypoints=websecure"
      - "traefik.http.routers.nextcloud.rule=Host(`nextcloud.deinedomain.de`)" # TODO: Domain anpassen
      - "traefik.http.routers.nextcloud.tls=true"
      - "traefik.http.routers.nextcloud.tls.certresolver=le"
      - "traefik.http.routers.nextcloud.middlewares=nextcloud-security"

      # Security Headers Middleware
      - "traefik.http.middlewares.nextcloud-security.headers.stsSeconds=15552000"
      - "traefik.http.middlewares.nextcloud-security.headers.stsIncludeSubdomains=true"
      - "traefik.http.middlewares.nextcloud-security.headers.stsPreload=true"
      - "traefik.http.middlewares.nextcloud-security.headers.forceSTSHeader=true"
      - "traefik.http.middlewares.nextcloud-security.headers.customFrameOptionsValue=SAMEORIGIN"
      - "traefik.http.middlewares.nextcloud-security.headers.contentTypeNosniff=true"
      - "traefik.http.middlewares.nextcloud-security.headers.browserXssFilter=true"
      - "traefik.http.middlewares.nextcloud-security.headers.referrerPolicy=no-referrer"
      - "traefik.http.middlewares.nextcloud-security.headers.permissionsPolicy=geolocation=(self), microphone=()"
      - "traefik.http.middlewares.nextcloud-security.headers.customResponseHeaders.X-Robots-Tag=noindex,nofollow"
      - "traefik.http.middlewares.nextcloud-security.headers.customResponseHeaders.X-Permitted-Cross-Domain-Policies=none"

      # Service
      - "traefik.http.services.nextcloud.loadbalancer.server.port=80"