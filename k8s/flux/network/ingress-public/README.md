# ingress-public

Traefik fürs Internet auf `192.168.178.232`, gebaut wie
[`ingress-internal`](../ingress-internal/README.md) - mit diesen Unterschieden:

- **Kette am Entrypoint** `websecure` (`public-chain`): CrowdSec-Bouncer,
  Security-Header, Ratelimit. Am Entrypoint, damit kein Ingress sie vergessen
  kann.
- **Zertifikat je Router** statt Wildcard; öffentliche Namen stehen ohnehin im
  DNS.
- **`externalTrafficPolicy: Local`**, sonst sähe CrowdSec alle Clients unter der
  Node-Adresse.
- **`forwardedHeaders.trustedIPs: []`**: Kein Proxy davor, also überschreibt
  Traefik `X-Forwarded-*`, statt sie zu übernehmen.
- **`TLSOption` mit `sniStrict`**: Unbekannte Namen enden im Handshake.

> **Stand:** whoami ist der einzige Dienst. Immich und Nextcloud laufen noch auf
> dem Unraid-Host; die Stellen zum Nachziehen sind im Ordner als BAUSTELLE
> markiert. AppSec kommt mit dem ersten Dienst, den eine WAF-Regel schützen
> soll; die Fritzbox-Freigabe zuletzt.
