# apps

Was der Cluster für Menschen bereitstellt. An dieser Gruppe hängt nichts - sie
darf scheitern.

| Komponente | Was |
|---|---|
| [`headlamp/`](headlamp) | Cluster-Dashboard unter `dashboard.k8s.nico-steinmueller.de` |
| [`Whoami.yaml`](Whoami.yaml) | Testdienst aus dem lokalen Chart `k8s/whoami/chart` |
| [`Sources.yaml`](Sources.yaml) | HelmRepository `headlamp` |

## `Whoami.yaml`

HelmRelease auf das lokale Chart über die `GitRepository flux-system`. Den
Namespace legt `core` an (`createNamespace: false` in `values-prod.yaml`). Werte je Umgebung: `k8s/whoami/README.md`.

> **`reconcileStrategy: Revision`** ist Pflicht: Mit der Voreinstellung
> `ChartVersion` bleibt jede Änderung am Chart still wirkungslos, solange
> `version` in `Chart.yaml` steht - Flux grün, im Cluster nichts. Nachzusehen
> an `kubectl -n flux-system get helmchart`.
