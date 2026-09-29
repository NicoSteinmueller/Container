# apps

Was der Cluster für Menschen bereitstellt. An dieser Gruppe hängt nichts - sie
darf scheitern.

| Komponente                     | Was                                                          |
|--------------------------------|--------------------------------------------------------------|
| [`headlamp/`](headlamp)        | Cluster-Dashboard unter `dashboard.k8s.nico-steinmueller.de` |
| [`ntfy/`](ntfy)                | Push-Benachrichtigungen unter `ntfy.nico-steinmueller.de`    |
| [`Whoami.yaml`](Whoami.yaml)   | Testdienst aus dem lokalen Chart `k8s/whoami/chart`          |
| [`Sources.yaml`](Sources.yaml) | HelmRepositories                                             |
