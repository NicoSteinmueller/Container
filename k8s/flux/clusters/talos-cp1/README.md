# Wurzel-Verzeichnis für Flux

Was hier liegt, rollt Flux automatisch aus - dies ist der `sync.path` der
FluxInstance aus `../../main.tf`.

## `whoami.yaml`

`HelmRelease` auf das lokale Chart `k8s/whoami/chart` (Deployment, Service,
NetworkPolicy, Namespace, Ingress). `sourceRef` zeigt auf die
`GitRepository flux-system` - kein zweites Source-Objekt nötig.

`valuesFiles` wählt die Umgebung; `values-prod.yaml` setzt `service.type:
NodePort` auf `30083`. Eine Ingress-Variante liegt dort auskommentiert bereit
(`ingressClassName: internal`) - sie ist vorerst wirkungslos, denn dieser
Cluster hat derzeit keinen Ingress-Controller und damit keine IngressClass.
Werte pro Umgebung: `k8s/whoami/README.md`.

```bash
kubectl -n flux-system get helmrelease whoami
kubectl -n whoami get pods,svc
curl http://<node-ip>:30083
```

## `secrets.yaml`

Die zweite Git-Quelle: `GitRepository` auf `homelab-secrets` im Gitea plus die
`Kustomization`, die sie anwendet. Der `decryption`-Block darin ist die
eigentliche Zeile — ohne ihn landete `ENC[AES256_GCM,...]` wörtlich als Wert im
Cluster, und die Kustomization bliebe dabei grün.

Warum ein zweites Repo statt einer Datei hier: Dieses geht öffentlich nach
GitHub, und auch Ciphertext soll dort nicht liegen. Begründung im Kopf der
Datei, Umgang damit in [../../README.md](../../README.md#secrets).

```bash
kubectl -n flux-system get gitrepository homelab-secrets
kubectl -n flux-system get kustomization homelab-secrets

# Beweisfall - erwartet wird "entschluesselt":
kubectl -n flux-system get secret sops-smoketest \
  -o jsonpath='{.data.probe}' | base64 -d; echo
```

## `reloader.yaml`

Startet neu, was ein geändertes Secret benutzt — sonst arbeitet ein Pod nach
einer Rotation bis zu seinem nächsten Start mit dem alten Wert weiter. Fremder
Chart, deshalb eine eigene `HelmRepository`.

Wen er anfasst, regelt er selbst: `autoReloadAll: true` mit
`ignoreNamespaces` als Ausnahmeliste — alles gilt als annotiert, außer
`kube-system`, `flux-system` und `reloader`. Vorher setzte Kyverno die
Annotation `reloader.stakater.com/auto` cluster-weit; mit dem Plattform-Stack
fiel Kyverno weg, und Reloader lief eine Zeit lang wirkungslos. Dieselbe Regel,
ein Controller weniger — Begründung je Namespace steht in
[reloader.yaml](reloader.yaml).

```bash
kubectl -n reloader get pods
kubectl -n reloader logs deploy/reloader-reloader | tail
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
