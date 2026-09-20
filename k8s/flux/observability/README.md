# observability

Metriken, Logs und die Auslastungsanzeigen — alles im Namespace `monitoring`,
für den `monitoring-egress` aus [`monitoring.yaml`](monitoring.yaml) gilt.

| Datei | Was |
|---|---|
| [`monitoring.yaml`](monitoring.yaml) | kube-prometheus-stack: Operator, Prometheus, Alertmanager, kube-state-metrics, node-exporter, Grafana |
| [`logs.yaml`](logs.yaml) | Loki als Speicher, Alloy als Sammler |
| [`metrics-server.yaml`](metrics-server.yaml) | `kubectl top` und die Balken in Headlamp |

Die eigenen Dashboards liegen in [`../grafana-dashboards`](../grafana-dashboards)
— eigene Gruppe, weil ein `configMapGenerator` eine `kustomization.yaml` braucht.

## `monitoring.yaml`

Grafana unter `grafana.k8s.nico-steinmueller.de`.

**Vorher lief hier VictoriaMetrics**, und die Begründung war ausschließlich das
RAM: Am 2026-09-11 lag der Node bei 2717 von 3276 MiB. Seit die VM auf 24 GiB
steht (2026-09-18, Requests bei 15 %), ist das Argument weg. Umgestellt am
2026-09-19. Was der Wechsel einbrachte:

- **Kein Sync-Job.** Der VM-Chart holte Dashboards und Regeln beim Deployen aus
  dem Netz — eine bewegliche Quelle. Jetzt liegen beide in der gepinnten Chart.
- **Die `monitoring.coreos.com`-CRDs kommen mit.** Vorher fehlten sie;
  `serviceMonitor.enabled: true` in [`../platform/reloader.yaml`](../platform/reloader.yaml)
  wäre kein Schalter gewesen, sondern ein Fehlschlag der HelmRelease.
- **Kein Internet-Egress mehr im Namespace.**

**Eine Einstellung trägt das Ganze:** `serviceMonitorSelectorNilUsesHelmValues`
und die drei Geschwister stehen auf `false`. Ab Werk `true`, und dann beachtet
Prometheus nur Objekte mit dem Release-Label dieser Chart — alles aus fremden
Charts würde stillschweigend ignoriert, ohne Fehler oder Warnung.

### Was auf Talos nicht scrapebar ist

`kubeEtcd`, `kubeControllerManager` und `kubeScheduler` stehen im Chart auf
`true` und wären hier dauerhaft rot: etcd lauscht mit Client-Zertifikaten und
ist von der Ingress-Firewall ohnehin zu, die beiden Static Pods bindet Talos auf
`127.0.0.1`. Sie sind deshalb **aus** und nicht ignoriert — ein Monitoring,
dessen Startzustand kaputte Targets sind, bringt niemandem bei, auf rote Targets
zu achten. `kubeProxy` muss *aktiv* aus, weil Cilium ihn ersetzt.

Das Kubelet wird über HTTPS, aber ungeprüft gescrapt (`insecureSkipVerify:
true`) — dieselbe Lücke wie beim metrics-server, mit demselben Grund: kein
kubelet-csr-approver.

### Der Admission-Webhook

Der Operator validiert `PrometheusRule`- und `ServiceMonitor`-Objekte über einen
Webhook, den der **kube-apiserver anruft**. Bei einem Namespace mit
`default-deny-ingress` braucht das eine eigene Regel:
`monitoring-operator-webhook`, `fromEntities: [kube-apiserver, host]` auf Port
`10250`. `fromEntities`, weil eine `kind: NetworkPolicy` es nicht kann — der
kube-apiserver ist auf Talos ein Static Pod mit hostNetwork. Und `10250` ist
hier der Webhook, nicht das Kubelet.

Fehlt die Regel, nimmt der Cluster keine Monitoring-CRs mehr an, und die Meldung
redet von einem Timeout gegen einen Service, der läuft. cert-manager und
CloudNativePG lösen dasselbe anders: Ihre Namespaces haben gar kein
Ingress-Default-Deny. Hier ist das keine Option, weil Grafana ausschließlich über
`traefik-internal` erreichbar sein soll.

Die Zertifikate stellt **cert-manager** aus, nicht die beiden Helm-Hook-Jobs der
Chart — die ziehen `ghcr.io/jkroepke/kube-webhook-certgen`, einen Fork eines
Dritten, der mit Cluster-Admin-Rechten läuft.

### Was noch fehlt

- **Ein Empfänger für Alarme.** Alertmanager läuft ohne Route, jeder Alarm endet
  im `null`-Receiver. Der Weg dahin steht in
  [../../../uptime-kuma/todo.md](../../../uptime-kuma/todo.md).
- **Ein Blick von außen.** Weder Metriken von innen noch Logs beantworten, ob der
  Ingress aus dem Internet antwortet.

### Voraussetzung

Das Secret `grafana-admin` mit `admin-user` und `admin-password` muss in
`homelab-secrets` liegen, sonst startet Grafana nicht.

```bash
kubectl -n monitoring get pods
kubectl -n monitoring get prometheus,alertmanager,servicemonitor
kubectl -n flux-system get helmrelease kube-prometheus-stack loki alloy

# Targets, die nicht antworten - erste Stelle ist monitoring-egress
kubectl -n kube-system exec ds/cilium -- \
  hubble observe --namespace monitoring --type drop --last 100
```

## `logs.yaml`

**Warum Loki:** Grafana kennt genau zwei Log-Datasources ohne Plugin, Loki und
Elasticsearch. VictoriaLogs wäre als Dienst einfacher, braucht aber ein Plugin —
und damit ein eigenes Grafana-Image, eine Registry und ein Pull-Secret.

**Warum die Loki-Werte so ausführlich sind:** Die Chart rendert mit ihren
Defaults nicht einmal (`Please define loki.storage.bucketNames.chunks`). Sie ist
auf `SimpleScalable` mit Object Storage ausgelegt — `read`/`write`/`backend` je
3 Replicas, zwei memcached-Caches, nginx-Gateway, Canary und Test-Pod. Abgeräumt
bleibt **ein StatefulSet mit einem Pod**. Der Aufwand liegt einmalig in der
Chart, nicht im Betrieb.

Zwei Fallen darin bleiben still: `retention_enabled: true` am Compactor — ohne
das ist `retention_period` wirkungslos und Loki sammelt für immer. Und
`auth_enabled: false`, weil Loki sonst pro Abfrage einen `X-Scope-OrgID`-Header
erwartet und ohne ihn mit „no org id" antwortet, was in Grafana wie ein kaputter
Datasource aussieht.

**Alloy und nicht Promtail:** Promtail ist seit 2026-03-02 End-of-Life.

Alloy liest die Container-Logs als Dateien unter `/var/log/pods` (hostPath, daher
`privileged` am Namespace) und nicht über `loki.source.kubernetes` — letzteres
liest sie durch den kube-apiserver, und damit hinge die Log-Sammlung an der
Komponente, deren Aussetzer man untersuchen will. Dazu
`loki.source.kubernetes_events`: was `kubectl get events` zeigt, aber mit
Geschichte statt nach einer Stunde verfallen.

Der Alloy-Config ist mit `alloy validate` gegen `grafana/alloy:v1.19.2` geprüft.

## `metrics-server.yaml`

Läuft in `kube-system` mit `--kubelet-insecure-tls`. Ohne ihn bleiben die
Auslastungsbalken in Headlamp leer und `kubectl top` antwortet nicht.

## Eigene Dashboards

**Warum nicht „Import via grafana.com" in der Oberfläche:** Ein so importiertes
Dashboard liegt nur im PVC, ist nicht reviewbar und nicht gepinnt — und bräuchte
einen Weg ins Internet für Grafana, den es hier bewusst nicht gibt. So braucht
das Netz nur die Arbeitsstation, einmal beim Herunterladen.

Anleitung zum Dazunehmen in
[`../grafana-dashboards/kustomization.yaml`](../grafana-dashboards/kustomization.yaml).
