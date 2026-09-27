# observability

Metriken, Logs, Auslastung

| Komponente                                 | Was                                                                                         |
|--------------------------------------------|---------------------------------------------------------------------------------------------|
| [`monitoring/`](monitoring)                | kube-prometheus-stack: Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics |
| [`Loki.yaml`](Loki.yaml)                   | Speicher für die Logs                                                                       |
| [`Alloy.yaml`](Alloy.yaml)                 | sammelt die Logs                                                                            |
| [`MetricsServer.yaml`](MetricsServer.yaml) | `kubectl top` und die Balken in Headlamp                                                    |
| [`Sources.yaml`](Sources.yaml)             | HelmRepositories                                                                            |


## Eigene Dashboards

In [`monitoring/dashboards`](monitoring/dashboards/kustomization.yaml), heruntergeladen und gepinnt