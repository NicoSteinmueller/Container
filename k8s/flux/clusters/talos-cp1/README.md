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
