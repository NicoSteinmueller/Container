# k8s/whoami

Kubernetes-Variante des `whoami`-Dienstes, parallel zum bestehenden Docker-Compose-Setup (`whoami/compose*.yml`). Läuft eigenständig, ersetzt die Docker-Container nicht.

Als Helm-Chart (`chart/`) statt Kustomize – der Grund ist derselbe wie beim Docker-Compose-Setup: mehrere Umgebungen (lokal in Minikube, später weitere), die sich nur in wenigen Werten unterscheiden (Ingress-Controller, Host, IP-Beschränkung). Ein Chart mit `values-<env>.yaml` pro Umgebung bildet das direkter ab als Kustomize-Overlays mit teils dupliziertem YAML.

## `chart/` – das Chart

| Datei | Zweck |
|---|---|
| `Chart.yaml` | Metadaten (Name, Version). |
| `values.yaml` | Sichere Voreinstellung: kein Ingress, kein öffentlicher Ingress, `networkPolicy.ingressControllerNamespaces` leer – niemand darf whoami ansprechen, solange keine Umgebung das gezielt öffnet. |
| `values-minikube.yaml` | Lokales Testsetup: NGINX-Ingress, Host `whoami.k8s.local`, kein TLS. |
| `values-prod.yaml` | Produktiv-Cluster (talos-cp1). `service.type: ClusterIP` plus Ingress über `ingressClassName: internal`, Host `whoami.k8s.nico-steinmueller.de`. TLS noch aus: Traefik liefert bis zur internen CA sein selbstsigniertes Zertifikat aus. |
| `templates/namespace.yaml` | Eigener Namespace `whoami`, Labels `pod-security.kubernetes.io/enforce: restricted` und `homelab.io/zone` (aus `zone`, siehe Template-Kommentar). |
| `templates/deployment.yaml` | Workload: Image `traefik/whoami:v1.12.0`, per Digest gepinnt, Security-Context (read-only Filesystem, non-root 1000:1000, alle Capabilities gedroppt, Seccomp `RuntimeDefault`), Liveness-/Readiness-Probes. |
| `templates/service.yaml` | DNS-Name `whoami.whoami.svc.cluster.local`. `service.type`/`service.nodePort` steuern `ClusterIP` (Default) vs. `NodePort`. |
| `templates/networkpolicy.yaml` | Default-Deny + Egress nur zu CoreDNS. Ingress erlaubt entweder nur aus den `networkPolicy.ingressControllerNamespaces` (Ingress-Betrieb; seit ingress-public eine Liste, weil whoami an beiden Controllern hängt) oder – bei `service.type: NodePort` – ohne Quellen-Einschränkung auf Port 80. Eine `ipBlock`-Beschränkung wäre technisch möglich (die frühere Begründung, Cilium werte ipBlock bei NodePort-Traffic nicht aus, war aus dem Egress-Fall übertragen und ist widerlegt – siehe Template-Kommentar); sie bleibt bei diesem Testdienst bewusst weg. |
| `templates/ingress.yaml` | Nur gerendert, wenn `ingress.enabled: true`. |

## Warum kein Ingress-Controller-Wert fest im Chart steht

`ingressClassName`, Host und die Ingress-Controller-Namespace für die NetworkPolicy unterscheiden sich pro Umgebung (NGINX in Minikube, Traefik im Produktiv-Cluster) – deshalb Werte, keine Vorlage, die pro Umgebung kopiert wird.

## Deployen

**Lokal in Minikube** (kein Flux, direktes `helm`):

```bash
helm upgrade --install whoami k8s/whoami/chart \
  -f k8s/whoami/chart/values.yaml \
  -f k8s/whoami/chart/values-minikube.yaml
```

**Im Produktiv-Cluster (talos-cp1):** über Flux, nicht von Hand – siehe `k8s/flux/clusters/talos-cp1/whoami.yaml` und `k8s/flux/clusters/talos-cp1/README.md`. Push auf den Sync-Branch reicht. Erreichbar danach unter `https://whoami.k8s.nico-steinmueller.de` aus dem LAN – der Name muss dort auf die LAN-Adresse des Nodes zeigen, und der Namespace `whoami` muss in der Namespace-Liste von ingress-internal stehen.

## Sicherheits-Mapping gegenüber Docker Compose

| Compose | Kubernetes |
|---|---|
| `security_opt: no-new-privileges` | `allowPrivilegeEscalation: false` |
| `cap_drop: ALL` | `capabilities.drop: [ALL]` |
| `read_only: true` | `readOnlyRootFilesystem: true` |
| `user: 1000:1000` | `runAsNonRoot`, `runAsUser/Group: 1000` |
| `deploy.resources.limits` | `resources.requests/limits` |
| Traefik `ipallowlist` (local-only) | noch offen, siehe unten |
| – (kein Äquivalent in Compose) | Namespace-PodSecurity „restricted", Default-Deny-NetworkPolicy, `seccompProfile: RuntimeDefault` |

**Offen:** Die IP-Beschränkung aus Compose (`local-only`-Middleware) ist noch nicht nachgebildet. Im Produktiv-Cluster reicht `ingressClassName: internal` allein schon dafür, dass whoami nicht aus dem Internet erreichbar ist (nur aus dem LAN über die interne Traefik-Instanz) – das ist aber gröber als eine IP-Allowlist. Eine echte Allowlist bräuchte auf Traefik eine `Middleware`-CRD (`ipAllowList`, per Annotation am Ingress referenziert) statt der NGINX-Annotation `whitelist-source-range`; kommt als eigener Schritt, sobald das irgendwo im Repo gebraucht wird.
