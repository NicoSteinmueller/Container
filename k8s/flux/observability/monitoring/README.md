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
- **Kubelet** über HTTPS, aber ungeprüft (`insecureSkipVerify`) - wie beim
  metrics-server, mangels kubelet-csr-approver.
- **Admission-Webhook** des Operators braucht `monitoring-operator-webhook`
  (siehe [../../core/README.md](../../core/README.md)). Seine Zertifikate kommen
  von cert-manager statt aus den Helm-Hook-Jobs der Chart (Fremd-Image mit
  Cluster-Admin).
- **Voraussetzung:** Secret `grafana-admin` (`admin-user`, `admin-password`) in
  `homelab-secrets`, sonst startet Grafana nicht.

**Offen:** ein Empfänger für Alarme (alles endet im `null`-Receiver, siehe
[uptime-kuma/todo.md](../../../../uptime-kuma/todo.md)) und ein Blick von außen
auf den öffentlichen Ingress.

```bash
kubectl -n monitoring get pods,prometheus,alertmanager,servicemonitor
kubectl -n kube-system exec ds/cilium -- hubble observe --namespace monitoring --type drop --last 100
```
