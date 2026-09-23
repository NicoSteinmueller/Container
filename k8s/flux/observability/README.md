# observability

Metriken, Logs, Auslastung - alles im Namespace `monitoring`.

| Komponente | Was |
|---|---|
| [`monitoring/`](monitoring) | kube-prometheus-stack: Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics |
| [`Loki.yaml`](Loki.yaml) | Speicher für die Logs |
| [`Alloy.yaml`](Alloy.yaml) | sammelt die Logs und schreibt sie nach Loki |
| [`MetricsServer.yaml`](MetricsServer.yaml) | `kubectl top` und die Balken in Headlamp; läuft in `kube-system` |
| [`Sources.yaml`](Sources.yaml) | HelmRepositories `prometheus-community`, `grafana`, `metrics-server` |

## Loki und Alloy

- **Loki**, weil Grafana es ohne Plugin kann (VictoriaLogs bräuchte ein eigenes
  Grafana-Image).
- **Die Loki-Werte sind lang**, weil die Chart auf SimpleScalable mit
  Objektspeicher ausgelegt ist; übrig bleibt ein StatefulSet mit einem Pod.
  Still wirkungslos ohne: `retention_enabled: true` (sonst wächst Loki ewig) und
  `auth_enabled: false` (sonst „no org id“ in Grafana).
- **Alloy statt Promtail** (EOL seit 2026-03-02). Liest `/var/log/pods` per
  hostPath - daher `privileged` - statt über die API, damit die Logsammlung
  nicht an der Komponente hängt, die man gerade untersucht. Dazu die
  Kubernetes-Events mit Verlauf.

## Eigene Dashboards

In [`../grafana-dashboards`](../grafana-dashboards/kustomization.yaml),
heruntergeladen und gepinnt statt „Import via grafana.com“: reviewbar, und
Grafana braucht keinen Weg ins Internet.
