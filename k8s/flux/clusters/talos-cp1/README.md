# Wurzel-Verzeichnis für Flux

Hier liegt die Wurzel, die die FluxInstance aus `../../main.tf` beobachtet
(`sync.path`). Alles, was hier als Manifest liegt, rollt Flux automatisch auf
den Cluster aus.

## `whoami.yaml`

Flux-`Kustomization`, die `k8s/whoami/base` einbindet (Deployment, Service,
NetworkPolicy, Namespace) - bewusst ohne `overlays/prod`, weil dessen
`ingress.yaml` von einem NGINX-Ingress-Controller ausgeht
(`ingressClassName: nginx`). Dieser Cluster hat nur die Traefik-basierten
IngressClasses `public`/`internal` aus
`k8s/platform/charts/homelab-base/templates/ingressclasses.yaml` - ein
NGINX-Ingress würde nie `Ready` werden. Siehe auch den "Offen"-Abschnitt in
`k8s/whoami/README.md`.

Nächster Schritt, sobald whoami sauber läuft: eine Traefik-taugliche
Ingress-Variante (`ingressClassName: internal`, analog zu Headlamp in
`k8s/platform/values/headlamp.yaml.tftpl`), dann per weiterer Flux-Ressource
hier ergänzen.

Prüfen nach dem Sync:

```bash
kubectl -n flux-system get kustomization whoami
kubectl -n whoami get pods,svc
```
