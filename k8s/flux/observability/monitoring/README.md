# monitoring

kube-prometheus-stack, Grafana unter `grafana.k8s.nico-steinmueller.de`. Dashboards
und Regeln kommen gepinnt mit der Chart, eigene Dashboards in
[`dashboards/`](dashboards/kustomization.yaml), die `monitoring.coreos.com`-CRDs sind da, 
kein Internet-Egress.

- **`serviceMonitorSelectorNilUsesHelmValues: false`** (und die drei
  Geschwister) trägt das Ganze: Ab Werk sähe Prometheus nur Objekte dieser Chart
  und ignorierte alle anderen stillschweigend.
- **Auf Talos nicht scrapebar** und deshalb aus statt dauerhaft rot: etcd,
  Controller-Manager, Scheduler (an `127.0.0.1` gebunden), kube-proxy (ersetzt
  durch Cilium).
- **Kubelet** über HTTPS, aber ungeprüft (`insecureSkipVerify`, Chart-Default) - wie beim
  metrics-server, mangels kubelet-csr-approver.
- **Admission-Webhook** des Operators braucht `monitoring-operator-webhook`
  (siehe [../../core/README.md](../../core/README.md)). Seine Zertifikate kommen
  von cert-manager statt aus den Helm-Hook-Jobs der Chart (Fremd-Image mit
  Cluster-Admin).
- **Keine clusterweiten Secret-Rechte** ([`RBAC.yaml`](RBAC.yaml)): Grafana
  liest nur ConfigMaps in `monitoring`, der Operator Secrets nur hier (die
  Regel nimmt ein `postRenderer` aus seiner ClusterRole), kube-state-metrics
  ohne Collector `secrets`. **Falle:** Der Operator beobachtet nur
  `monitoring` - ein ServiceMonitor anderswo wird still ignoriert.
- **Voraussetzung:** Secret `grafana-admin` (`admin-user`, `admin-password`) in
  `homelab-secrets`, sonst startet Grafana nicht.
- **Alarme an ntfy:** Was `thema: db-backup` trägt
  ([`DbBackupRules.yaml`](DbBackupRules.yaml)), geht ins Topic `db-backup`,
  direkt an den ntfy-Service mit einem Token, das nur dort schreiben darf
  (Secret `ntfy-alertmanager`). Eine neue Alarmgruppe: eigenes `thema`, eigene
  Route und eigener Empfänger in `HelmRelease.yaml`, dazu Benutzer oder Recht
  in `ntfy-auth`.

**Offen:** Alles andere endet weiter im `null`-Receiver, und ein toter
Cluster meldet sich nicht - ntfy läuft im selben Cluster. Dafür braucht es
einen Totmann außerhalb ([uptime-kuma/todo.md](../../../../uptime-kuma/todo.md)).
Dazu ein Blick von außen auf den öffentlichen Ingress.

```bash
kubectl -n monitoring get pods,prometheus,alertmanager,servicemonitor
kubectl -n kube-system exec ds/cilium -- hubble observe --namespace monitoring --type drop --last 100
```
