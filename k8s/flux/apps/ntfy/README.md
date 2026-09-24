# ntfy

Push-Benachrichtigungen unter `https://ntfy.nico-steinmueller.de`, umgezogen
aus dem Docker-Stack [`ntfy/`](../../../../ntfy). Der erste öffentliche Dienst
im Cluster.

## Der Weg

Nur über ingress-public (`.232`): TLS, CrowdSec, Header und Ratelimit wie
jeder öffentliche Dienst, Route in
[`../../network/ingress-public/DynamicConfig.yaml`](../../network/ingress-public/DynamicConfig.yaml).
Der Docker-Traefik ist nicht beteiligt.

Der Name muss dafür auf `.232` zeigen:

- **Im LAN** per AdGuard-Umschreibung `ntfy.nico-steinmueller.de ->
  192.168.178.232`, neben `whoami.nico-steinmueller.de`. Sie muss vor dem
  Wildcard `*.nico-steinmueller.de -> .5` greifen - AdGuard nimmt den genauen
  Namen vor dem Wildcard.
- **Aus dem Internet vorerst nicht** (Stand 2026-09-24): Die Fritzbox gibt 443
  an den Docker-Traefik, dort gibt es für ntfy keine Route. Erreichbar wird es
  mit der Freigabe auf `.232` (INBETRIEBNAHME.md, Schritt 11). Bis dahin
  erreicht ein Handy unterwegs ntfy nicht.

## Zugang

Benutzer, Rechte und Tokens stehen deklarativ im Secret `ntfy-auth`
(`homelab-secrets`, Schlüssel `NTFY_AUTH_USERS`, `NTFY_AUTH_ACCESS`,
`NTFY_AUTH_TOKENS`) und sind dieselben wie unter Docker - Clients ändern
nichts. `auth.db` entsteht daraus bei jedem Start neu. Ein Token von Hand
(`ntfy token add`) überlebt einen Volume-Verlust nicht; er gehört ins Secret.

```bash
sops edit cluster/ntfy-auth.sops.yaml          # in homelab-secrets
# Passwort-Hash: kubectl -n ntfy exec deploy/ntfy -- ntfy user hash
```

Der Nachrichten-Cache der Docker-Zeit ist nicht übernommen (699 Nachrichten
bis 10.09.2026, längst zugestellt).

## Prüfen

```bash
curl -s https://ntfy.nico-steinmueller.de/v1/health                  # {"healthy":true}
curl -s -o /dev/null -w '%{http_code}\n' https://ntfy.nico-steinmueller.de/test/json?poll=1   # 403 ohne Login
kubectl -n traefik-public logs deploy/traefik-public | grep ntfy | tail -3 # ClientHost = echte Adresse
```
