# k8s/whoami

Kubernetes-Variante des `whoami`-Dienstes, parallel zum bestehenden Docker-Compose-Setup (`whoami/compose*.yml`). Läuft eigenständig in Minikube, ersetzt die Docker-Container nicht.

Die Struktur folgt bewusst dem gleichen Muster wie die Compose-Dateien: **`base/`** entspricht `compose.yml` (Grundkonfiguration, gilt überall), **`overlays/`** entsprechen `compose.override.yml`/`compose.prod.yml` (umgebungsspezifische Ergänzungen). [Kustomize](https://kustomize.io) baut daraus die finalen Manifeste zusammen.

## `base/` – gilt in jeder Umgebung

| Datei | Zweck |
|---|---|
| `namespace.yaml` | Eigener Namespace `whoami` – isoliert den Dienst von anderen. Trägt das Label `pod-security.kubernetes.io/enforce: restricted`, das Kubernetes zwingt, jeden Pod in diesem Namespace gegen den strengsten Sicherheitsstandard zu prüfen (non-root, keine Privilege-Escalation, Capabilities gedroppt etc.) – verstößt ein Pod dagegen, lehnt die API ihn direkt ab. |
| `deployment.yaml` | Der eigentliche Workload: welches Image (`traefik/whoami:v1.12.0`, per Digest gepinnt), wie viele Replicas, Resource-Limits, Security-Context (read-only Filesystem, non-root User 1000:1000, alle Linux-Capabilities gedroppt, Seccomp `RuntimeDefault`), Liveness-/Readiness-Probes. |
| `service.yaml` | Stabiler interner DNS-Name (`whoami.whoami.svc.cluster.local`) + Load-Balancing zwischen den Pods. Nur clusterintern erreichbar (`ClusterIP`), kein direkter Außenzugriff. |
| `networkpolicy.yaml` | Drei Regeln: (1) Default-Deny – ohne explizite Erlaubnis darf nichts rein oder raus, (2) Ingress nur vom Ingress-Controller erlaubt, (3) Egress nur zu CoreDNS (Port 53) erlaubt. **Hinweis:** wird von Minikube aktuell nicht durchgesetzt (fehlendes NetworkPolicy-fähiges CNI), greift aber sobald ins Produktiv-Cluster mit Calico/Cilium gewechselt wird. |
| `kustomization.yaml` | Fasst die vier Dateien oben zu einer Einheit zusammen, die `overlays/` referenzieren können. |

## `overlays/minikube/` – nur für lokale Tests

| Datei | Zweck |
|---|---|
| `ingress.yaml` | Macht den Service über HTTP von außen (aus dem lokalen Netz) erreichbar unter `whoami.k8s.local`, via NGINX-Ingress-Controller. Kein TLS, keine IP-Beschränkung – reines Testsetup. Erfordert einen `/etc/hosts`-Eintrag auf die Minikube-IP (wird von `ansible/minikube-install.yml` automatisch verwaltet, siehe Variable `k8s_local_hosts`). |
| `kustomization.yaml` | Nimmt `base/` und ergänzt die minikube-spezifische Ingress. |

## `overlays/prod/` – Vorbereitung fürs spätere Produktiv-Cluster

| Datei | Zweck |
|---|---|
| `ingress.yaml` | Wie oben, aber mit `whoami.nico-steinmueller.de`, IP-Allowlist `192.168.178.0/24` (Äquivalent zur `local-only`-Traefik-Middleware) und einem TLS-Block, der aktiv wird, sobald cert-manager im Ziel-Cluster installiert ist (aktuell auskommentiert). |
| `kustomization.yaml` | Nimmt `base/` und ergänzt die Prod-Ingress. |

## Deployen

```bash
# lokal in Minikube
kubectl apply -k k8s/whoami/overlays/minikube

# später im Produktiv-Cluster
kubectl apply -k k8s/whoami/overlays/prod
```

Kustomize baut daraus automatisch alle Objekte (Namespace, Deployment, Service, NetworkPolicies, Ingress) und wendet sie an.

## Sicherheits-Mapping gegenüber Docker Compose

| Compose | Kubernetes |
|---|---|
| `security_opt: no-new-privileges` | `allowPrivilegeEscalation: false` |
| `cap_drop: ALL` | `capabilities.drop: [ALL]` |
| `read_only: true` | `readOnlyRootFilesystem: true` |
| `user: 1000:1000` | `runAsNonRoot`, `runAsUser/Group: 1000` |
| `deploy.resources.limits` | `resources.requests/limits` |
| Traefik `ipallowlist` (local-only) | `nginx.ingress.kubernetes.io/whitelist-source-range` |
| – (kein Äquivalent in Compose) | Namespace-PodSecurity „restricted", Default-Deny-NetworkPolicy, `seccompProfile: RuntimeDefault` |

**Offen:** Ob im echten Produktiv-Cluster Traefik (wie aktuell) oder NGINX als Ingress-Controller läuft, ist noch nicht entschieden. `overlays/prod/ingress.yaml` geht aktuell von NGINX aus. Falls ihr bei Traefik bleibt, müsste dort ein `IngressRoute`-CRD statt `Ingress` + NGINX-Annotations verwendet werden.
