# ingress-internal

Traefik fürs Heimnetz auf `192.168.178.231`. Von außen nur aus dem LAN
(`allow-from-lan`, `ipBlock`), an die Anwendungen nur über den Controller.

## RBAC von Hand

`rbac.namespaced: true` setzt im Chart zugleich
`--providers.kubernetesingress.disableClusterScopeResources=true`. Dann liest
Traefik keine IngressClasses, und jeder Ingress mit `ingressClassName` endet
still in 404. Deshalb `rbac.enabled: false` und eigene Objekte - die Rollen
gemeinsam mit ingress-public in [`../TraefikRBAC.yaml`](../TraefikRBAC.yaml),
die Bindungen in `RBAC.yaml`:

| ClusterRole | gebunden | Rechte |
|---|---|---|
| `traefik-cluster` | clusterweit | `nodes`, `namespaces`, `ingressclasses` |
| `traefik-namespaced` | per RoleBinding je Namespace | der Rest, **inkl. Secrets** |

- Bindungen heißen `<rolle>-internal`, nicht wie im Chart: `roleRef` ist
  unveränderlich, eine gleichnamige alte Bindung ließe jedes Apply scheitern.

## Dashboard

`https://traefik.k8s.nico-steinmueller.de`, mit Basic-Auth
(`traefik-dashboard-auth`, Secret in `homelab-secrets`) - „nur im LAN“ ist keine
Authentifizierung. Match nur auf `Host(...)`, sonst wäre die Adresse ohne Pfad
ein 404. Einen ungeschützten Weg über 8080 gibt es nicht (`api.insecure` aus).

```bash
python3 -c 'import bcrypt,getpass; print("nico:"+bcrypt.hashpw(getpass.getpass().encode(), bcrypt.gensalt(rounds=12)).decode())'
sops cluster/traefik-dashboard-auth.sops.yaml   # in homelab-secrets, gilt ohne Neustart
```

## Zertifikat

Wildcard `*.k8s.nico-steinmueller.de` von Let's Encrypt, DNS-01 über IONOS, von
Traefik selbst geholt und am Entrypoint hinterlegt - ein neuer Dienst braucht
keinen `tls:`-Block.

- **Traefik statt cert-manager**: cert-manager hat keinen IONOS-Solver.
- **Wildcard**: Einzelzertifikate schrieben jeden Dienstnamen in die
  Certificate-Transparency-Logs.
- API-Key als `traefik-ionos` in `homelab-secrets`, per `env` (lego liest nur
  die Umgebung).

> **Produktivverzeichnis** - Änderungen an der Challenge erst in Staging, die
> Rate-Limits sind hart. Bei jedem Wechsel muss `acme.json` weg, sonst wird
> das alte Zertifikat weiter ausgeliefert:
>
> ```bash
> kubectl -n traefik-internal exec deploy/traefik-internal -- rm -f /data/acme.json
> kubectl -n traefik-internal rollout restart deploy/traefik-internal
> ```

## Im Heimnetz

Nicht im Repo: Die Namen zeigen **nur intern** (AdGuard/Fritzbox) auf `.231`.
Die eigene Zone `k8s.` trennt sie von den Diensten auf dem Unraid-Host
(`*.local.…`) - ein Umzug ist damit ein sichtbarer Namenswechsel.

```
dashboard|grafana|traefik|whoami.k8s.nico-steinmueller.de  ->  192.168.178.231
```
