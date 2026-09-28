# ingress-public

Traefik fürs Internet auf `192.168.178.232`, gebaut wie
[`ingress-internal`](../ingress-internal/README.md)

- **Kette am Entrypoint** `websecure` (`public-chain`): CrowdSec-Bouncer,
  Security-Header, Ratelimit. Am Entrypoint, damit kein Ingress sie vergessen
  kann.
- **Zertifikat je Router** statt Wildcard; öffentliche Namen stehen ohnehin im
  DNS.