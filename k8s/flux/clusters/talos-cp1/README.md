# Wurzel-Verzeichnis für Flux

Hier liegt die Wurzel, die die FluxInstance aus `../../main.tf` beobachtet
(`sync.path`). Alles, was hier als Manifest liegt, rollt Flux automatisch auf
den Cluster aus.

## `whoami.yaml`

Flux-`HelmRelease`, die das lokale Chart `k8s/whoami/chart` installiert
(Deployment, Service, NetworkPolicy, Namespace, Ingress). `chart.spec.chart`
zeigt auf den Chart-Pfad im selben Repo, `sourceRef` auf dieselbe
`GitRepository flux-system`, die auch Kustomizations beobachten würden - kein
zweites Source-Objekt nötig.

`valuesFiles: [values.yaml, values-prod.yaml]` wählt die Umgebung.
`values-prod.yaml` setzt aktuell `service.type: NodePort` auf Port `30083` -
erster Schritt, direkt im LAN erreichbar ohne Ingress-Controller. Eine
Ingress-Variante liegt dort schon auskommentiert bereit (`ingressClassName:
internal`, da dieser Cluster nur die Traefik-basierten IngressClasses
`public`/`internal` aus
`k8s/platform/charts/homelab-base/templates/ingressclasses.yaml` kennt, kein
NGINX). Details zu den Werten pro Umgebung stehen in `k8s/whoami/README.md`.

Prüfen nach dem Sync:

```bash
kubectl -n flux-system get helmrelease whoami
kubectl -n whoami get pods,svc
curl http://<node-ip>:30083
```

## `headlamp.yaml`, `metrics-server.yaml`

Beide Charts kommen aus einem fremden Helm-Repository, nicht aus diesem
Repo - anders als whoami braucht `chart.spec.sourceRef` deshalb eine eigene
`HelmRepository` statt der `GitRepository flux-system`.

`headlamp.yaml` bringt zusätzlich Namespace und RBAC als eigene Manifeste
mit (Namespace `headlamp` mit PodSecurity "restricted", ServiceAccount
`headlamp` mit reinen Leserechten, ein zweiter `headlamp-admin` mit
`cluster-admin` aber ohne Pod und ohne Token) - das Chart selbst würde den
Namespace unbeschriftet anlegen und seinen ServiceAccount ab Werk an
`cluster-admin` binden. Details und die Abwägung dahinter stehen als
Kommentare in der Datei.

`metrics-server.yaml` ist die Datenquelle für die Auslastungsanzeigen in
Headlamp, läuft in `kube-system` mit `--kubelet-insecure-tls` (siehe
Kommentare dort - `vm/talos-simple` hat kein `serverTLSBootstrap`).

Zugang zu Headlamp: `service.type: NodePort` auf Port `30080` - HTTP, nicht
HTTPS, vertretbar im eigenen LAN (dieser Cluster hat weder
Ingress-Controller noch cert-manager). Anmeldung per Token:

```bash
kubectl -n headlamp create token headlamp --duration=8h        # Lesen
kubectl -n headlamp create token headlamp-admin --duration=1h  # Ändern
```

Prüfen nach dem Sync:

```bash
kubectl -n flux-system get helmrelease headlamp metrics-server
kubectl -n headlamp get pods,svc
curl http://<node-ip>:30080
```
