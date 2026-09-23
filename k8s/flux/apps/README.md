# apps

Was der Cluster für Menschen bereitstellt. Die einzige Gruppe, an der nichts
hängt — sie darf scheitern, ohne dass eine andere davon erfährt.

| Komponente | Was |
|---|---|
| [`headlamp/`](headlamp) | Cluster-Dashboard unter `dashboard.k8s.nico-steinmueller.de` |
| [`Whoami.yaml`](Whoami.yaml) | Testdienst aus dem lokalen Chart `k8s/whoami/chart` |
| [`Sources.yaml`](Sources.yaml) | HelmRepository `headlamp` |

## `headlamp/`

Fremder Chart, deshalb eine eigene `HelmRepository` (in `Sources.yaml`). RBAC
steht als eigene Manifeste in `RBAC.yaml`, weil das Chart seinen ServiceAccount ab Werk an
`cluster-admin` bindet (`clusterRoleBinding.create: false`):

| ServiceAccount | Rechte |
|---|---|
| `headlamp` | Identität des Pods und des Lese-Tokens. Kein Schreiben, keine Secrets. |
| `headlamp-admin` | `cluster-admin`, ohne Pod und ohne Token — wer ändern will, erzeugt sich eines für eine Stunde. |

Erreichbar nur über `traefik-internal`; die NetworkPolicy im Namespace lässt
sonst niemanden an den Pod. Der NodePort `30080` ist weg — das Token, das man
beim Aufruf einfügt, ging darüber im Klartext durchs LAN.

```bash
kubectl -n headlamp create token headlamp --duration=8h        # Lesen
kubectl -n headlamp create token headlamp-admin --duration=1h  # Ändern
```

## `Whoami.yaml`

`HelmRelease` auf das lokale Chart — `sourceRef` zeigt auf die `GitRepository
flux-system`, ein zweites Source-Objekt braucht es nicht. Den Namespace legt das
Chart selbst an, anders als bei allen anderen Diensten; er steht deshalb nicht in
[`../core/Namespaces.yaml`](../core/Namespaces.yaml).

`values-prod.yaml` setzt `service.type: ClusterIP` und einen Ingress auf
`ingressClassName: internal`. Werte pro Umgebung: `k8s/whoami/README.md`.

> `reconcileStrategy: Revision` ist dort die Zeile, ohne die jede Änderung am
> Chart oder an den valuesFiles **lautlos** wirkungslos bleibt: Die Voreinstellung
> `ChartVersion` packt das Chart nur neu, wenn `version` in `Chart.yaml` sich
> ändert — bei einem Chart im selben Repo bleibt die aber stehen. Genau das ist
> einmal passiert: Der Ingress war im Repo, Flux war grün, im Cluster stand
> nichts. Nachzusehen an der HelmChart, nicht an der HelmRelease:
> `kubectl -n flux-system get helmchart`.

```bash
kubectl -n flux-system get helmrelease whoami headlamp
kubectl -n whoami get pods,svc,ingress
curl -k https://whoami.k8s.nico-steinmueller.de
```
