# Wurzel-Verzeichnis für Flux

Was hier liegt, rollt Flux automatisch aus - dies ist der `sync.path` der
FluxInstance aus `../../main.tf`.

## `whoami.yaml`

`HelmRelease` auf das lokale Chart `k8s/whoami/chart` (Deployment, Service,
NetworkPolicy, Namespace, Ingress). `sourceRef` zeigt auf die
`GitRepository flux-system` - kein zweites Source-Objekt nötig.

`valuesFiles` wählt die Umgebung; `values-prod.yaml` setzt `service.type:
NodePort` auf `30083`. Eine Ingress-Variante liegt dort auskommentiert bereit
(`ingressClassName: internal` - dieser Cluster kennt nur die Traefik-Klassen
`public`/`internal` aus `k8s/platform`, kein NGINX). Werte pro Umgebung:
`k8s/whoami/README.md`.

```bash
kubectl -n flux-system get helmrelease whoami
kubectl -n whoami get pods,svc
curl http://<node-ip>:30083
```

## `headlamp.yaml`, `metrics-server.yaml`

Beide Charts kommen aus fremden Helm-Repositories - `chart.spec.sourceRef`
braucht deshalb je eine eigene `HelmRepository` statt der `GitRepository`.

`headlamp.yaml` bringt Namespace und RBAC als eigene Manifeste mit (PodSecurity
`restricted`, ServiceAccount `headlamp` nur lesend, `headlamp-admin` mit
`cluster-admin` ohne Pod und Token) - das Chart selbst würde den Namespace
unbeschriftet anlegen und seinen ServiceAccount an `cluster-admin` binden.
Begründungen stehen als Kommentare in der Datei.

`metrics-server.yaml` liefert die Auslastungsanzeigen, läuft in `kube-system`
mit `--kubelet-insecure-tls` (siehe Kommentare dort).

Headlamp per NodePort `30080`, HTTP - vertretbar im LAN, dieser Cluster hat
weder Ingress-Controller noch cert-manager. Anmeldung per Token:

```bash
kubectl -n headlamp create token headlamp --duration=8h        # Lesen
kubectl -n headlamp create token headlamp-admin --duration=1h  # Ändern
kubectl -n flux-system get helmrelease headlamp metrics-server
```
