# Cluster-Ausstattung

Was aus dem Talos-Node aus [../../vm/talos](../../vm/talos) ein Cluster macht,
in dem die Dienste aus dem Sicherheitskonzept laufen können: zwei
Ingress-Controller, eine interne CA, CrowdSec, Kyverno, Netzgrenzen und eine
StorageClass.

Der Aufbau folgt der Reihenfolge des Konzepts
([../homelab-sicherheitskonzept.html](../homelab-sicherheitskonzept.html)):
von der Außengrenze nach innen, und jede Grenze zweimal — einmal als Bindung,
einmal als Regel.

## Was hier entsteht

| Schicht | Komponente | Aufgabe |
|---|---|---|
| 1 | `homelab-base` (lokales Chart) | Namespaces mit Vertrauensstufen, IngressClasses, Default-Deny-NetworkPolicies, StorageClass |
| 2 | cert-manager, step-ca | Zertifikate: intern für das LAN, step-ca für die Strecke Edge → Cluster |
| 3 | `homelab-pki` (lokales Chart) | stellt das Serverzertifikat von `ingress-public` aus — im Namespace der CA, damit dort kein Provisioner-Passwort landet, wo Traefik lesen darf (E10) |
| 3 | Kyverno | erzwingt `ingressClassName: public` nur in gekennzeichneten Namespaces |
| 4 | `ingress-public`, `ingress-internal` | zwei Traefik-Instanzen, an je eine Adresse gebunden |
| 5 | CrowdSec | LAPI und Agent für die Anwendungslogs |
| 6 | `homelab-policies` (lokales Chart) | Policies, die Router zu LAPI und step-ca, ClusterIssuer, RBAC des Dashboards |
| 7 | `kubelet-csr-approver`, metrics-server, Headlamp | Einblick: echte Kubelet-Zertifikate, Auslastung, Dashboard im LAN |

## Voraussetzungen

- `vm/edge` und `vm/talos` sind angewendet, `kubectl get nodes` zeigt Ready
- `terraform`, `kubectl`, `helm` (für `helm diff`, optional)

## Anwenden

```bash
cd k8s/platform
cp terraform.tfvars.example terraform.tfvars   # Adressen anpassen
terraform init
terraform apply
```

Beim **allerersten** Lauf kann `data.kubernetes_config_map.step_ca_certs` leer
zurückkommen, wenn der Bootstrap-Job der CA noch nicht durch ist. Dann
schlägt der Apply fehl oder legt eine leere ConfigMap an — in beiden Fällen
hilft ein zweiter `terraform apply`.

Danach:

```bash
terraform output bootstrap_schritte
verify/assert-platform.sh
```

## Die drei Bootstrap-Schritte

Alles, was ein Geheimnis ist, kommt **nicht** aus Terraform — dieselbe Regel
wie bei der Edge-VM. Nach dem Anwenden fehlen deshalb drei Dinge:

```bash
# 1. Fingerprint der internen CA -> vm/edge/terraform.tfvars
kubectl -n step-ca exec sts/step-ca -- \
  step certificate fingerprint /home/step/certs/root_ca.crt

# dazu passend in vm/edge/terraform.tfvars:
#   step_ca_url                 = "https://10.10.20.3:9000"
#   step_ca_fingerprint         = "<Ausgabe von oben>"
#   cluster_ingress_ip          = "10.10.20.3"
#   cluster_ingress_server_name = "ingress-public.internal"
# danach dort: terraform apply

# 2. Client-Zertifikat der Edge-VM (Token läuft nach Minuten ab)
scripts/edge-token.sh edge1.dmz
ssh edge@192.168.178.20 sudo edge-mtls-bootstrap <token>

# 3. CrowdSec-Zugangsdaten für die Edge-VM
scripts/edge-register.sh
# gibt den fertigen edge-crowdsec-connect-Aufruf aus
```

Erst danach die Fritzbox-Freigabe setzen. `vm/edge/verify/proxy-test.sh` prüft
die Kette dann von außen.

## Die Strecke von der Edge in den Cluster

Die Edge-VM sieht genau drei Ports, alle auf `10.10.20.3`, alle auf
`ingress-public`:

| Port | Was | TLS |
|---|---|---|
| 443 | Nutzverkehr an `ingress-public` | terminiert, Client-Zertifikat **Pflicht** |
| 8443 | CrowdSec-LAPI | terminiert, Client-Zertifikat **Pflicht** |
| 9000 | step-ca | Passthrough |

Dass alle drei über denselben Controller laufen, ist Absicht: Die
mTLS-Prüfung steht dann an einer Stelle statt an dreien, und die
Talos-Ingress-Firewall hat genau eine Quelle freizugeben.

**Die mTLS-Pflicht** kommt aus einer Datei, nicht aus einer CRD:
`tls.options.default` im File-Provider von `ingress-public`
([values/traefik-public.yaml.tftpl](values/traefik-public.yaml.tftpl)). Zwei
Gründe: Sie gilt damit für *jeden* Router auf diesem Controller — auch für
einen, den morgen jemand anlegt und dabei die TLSOption vergisst. Und der
Vertrauensanker ist eine Datei, keine Secret-Referenz; eine TLSOption-CRD
bräuchte den Wurzel in einem Secret, das der Controller dann auch lesen
dürfte.

**step-ca läuft als Passthrough**, weil die Edge beim Bootstrap den
Fingerprint des Wurzelzertifikats prüft. Eine terminierende Zwischenstation
würde genau diese Prüfung aushebeln — und ein Client-Zertifikat kann die Edge
zu diesem Zeitpunkt noch nicht haben, sie holt es sich ja gerade.

**Das Serverzertifikat von `ingress-public`** entsteht dort, wo das
Provisioner-Passwort ohnehin liegt: im Namespace `step-ca`. Ein CronJob stellt
es alle sechs Stunden aus und legt es als gewöhnliches TLS-Secret in den
Namespace des Ingress ([charts/homelab-pki](charts/homelab-pki)). Laufzeit
sind dieselben 24 Stunden wie beim Client-Zertifikat der Edge (E5).

Das ist Entscheidung E10, und der Grund steht direkt daneben im selben Chart:
Traefik bekommt mit namespaced RBAC **Leserecht auf Secrets in seinem eigenen
Namespace**. Zwei Absätze weiter oben ist genau das der Grund, warum der
Wurzel als ConfigMap kopiert wird statt Traefik den Namespace der CA lesen zu
lassen — dieselbe Überlegung gilt in die andere Richtung. Ein
Provisioner-Passwort in `traefik-public` wäre nach einer Übernahme des Ingress
ein Schlüssel zur internen CA gewesen: Zertifikate auf jeden beliebigen Namen,
insbesondere auf `edge1.dmz`. Damit wäre das Client-Zertifikat als alleiniger
Türsteher (E5) wertlos, und das Argument aus E2 — der Ingress hat mehr Rechte,
als man annimmt — hätte sich gegen den eigenen Aufbau gerichtet.

Was jetzt in `traefik-public` liegt, ist der eigene Schlüssel des Ingress. Den
hat er ohnehin.

| | wo | was liegt dort |
|---|---|---|
| Aussteller | Namespace `step-ca` | Provisioner-Passwort, Wurzel, Schlüssel der CA |
| `ingress-public` | Namespace `traefik-public` | nur das eigene Zertifikat und der öffentliche Wurzel |

Ein Sidecar im Ingress-Pod bemerkt die Rotation und fasst die dynamische
Konfiguration an — Traefik liest Zertifikatsdateien nur beim Laden der
Konfiguration. Er kennt weder die CA noch ein Zugangsdatum; er sieht nur den
Zeitstempel der eingehängten Datei.

Verworfen wurde ein Token-Bootstrap wie auf der Edge-VM: Ein Token lebt fünf
Minuten. Auf der Edge trägt es ein Mensch ein, hier müsste es alle paar
Minuten erneuert werden — und ein Pod, der nach einem längeren Ausfall
startet, fände ein abgelaufenes vor. Der CronJob löst genau das: Im Secret
liegt immer ein Zertifikat, das höchstens sechs Stunden alt ist.

## Die zwei Ingress-Controller

Trennung nach Erreichbarkeit statt nach Konfiguration (E6):

| | `ingress-public` | `ingress-internal` |
|---|---|---|
| Bindung | `10.10.20.3:443` | `192.168.178.222:80,443` |
| Erreichbar für | nur die Edge-VM | das Heimnetz |
| Client-Zertifikat | Pflicht | nein |
| IngressClass | `public` | `internal` |
| Beobachtete Namespaces | `nextcloud`, `immich` | `paperless` |
| Zertifikate | step-ca (eines, für die Strecke) | cert-manager |

**RBAC ist namespaced.** Das Konzept nennt als stärkstes Argument für die
Edge-VM, dass ein Ingress-Controller mehr Rechte hat, als man annimmt — vor
allem Leserecht auf Secrets, weil dort die TLS-Zertifikate liegen. Mit
`rbac.namespaced: true` gilt das nur noch für die Namespaces, die der
Controller tatsächlich bedient. Die Namespaces von step-ca und CrowdSec
gehören ausdrücklich nicht dazu: Deren Dienste hängen an
ExternalName-Services, damit dort kein Leserecht entsteht — im Namespace der
CA läge sonst der Wurzelschlüssel im Sichtfeld des Proxys.

**`X-Forwarded-For`.** `ingress-public` vertraut genau einer Adresse: der
Edge-VM. Sie überschreibt den Header hart auf die TCP-Peer-Adresse und
verwirft alles, was der Client mitgeschickt hat — erst dadurch ist der Wert
hier etwas wert. Fehlt die Zeile, sieht CrowdSec bei jedem Angriff nur die
Edge-VM und sperrt am Ende den gesamten Zugang. `ingress-internal` vertraut
niemandem: Vor ihm steht kein Proxy.

## Kyverno: die Zeile, die über öffentlich entscheidet

```yaml
ingressClassName: public
```

Diese eine Zeile entscheidet, ob ein Dienst aus dem Internet erreichbar ist.
Die Topologie allein schützt nur gegen den harmlosen Tippfehler — ein aus
Nextcloud kopiertes Ingress-Manifest, das bei Paperless landet, exponiert es
genau so, wie es verhindert werden soll.

[charts/homelab-policies](charts/homelab-policies) lehnt das ab: `public` ist
nur in Namespaces mit `homelab.io/zone=public` zulässig, `Enforce`, nicht
`Audit`. Eine zweite Regel deckt denselben Weg über Traefiks eigene CRD ab,
eine dritte begrenzt `hostPort`/`hostNetwork` auf die Namespaces, die sie
brauchen.

Ausprobiert wird das in [verify/assert-platform.sh](verify/assert-platform.sh):
Ein `public`-Ingress in einem internen Namespace wird per
`kubectl apply --dry-run=server` durch die Admission-Kette geschickt und muss
abgelehnt werden. Eine Regel, die man nur liest, ist keine Abnahme.

## Netzgrenzen im Cluster

Default-Deny pro Anwendungs-Namespace, dann gezielt öffnen: DNS, der eigene
Namespace, der zuständige Ingress, und ausgehend HTTPS ins Internet — ohne
die privaten Netze. Das ist die Zusage „kein Pod erreicht das LAN".

**Was diese Zusage nicht abdeckt, und das gehört dazu:** Cilium wertet
`ipBlock`-Regeln nicht gegen die reservierten Identitäten `host` und
`remote-node` aus. Ein Pod kann den Node selbst also weiterhin ansprechen,
obwohl `192.168.178.0/24` ausgenommen ist. Was ihn dort erwartet, entscheidet
die Talos-Ingress-Firewall: Aus dem Pod-Netz sind Kubelet, KubePrism und die
Kubernetes-API erreichbar — nicht die Talos-API und nicht die drei DMZ-Ports.
Die beiden Ebenen ergänzen sich also; keine ist für sich vollständig.

Die beiden Ingress-Namespaces bekommen ebenfalls Default-Deny: Die
Traefik-Charts aktivieren die Dashboard-API auf einem Port, der zwar nicht
exponiert ist, den aber jeder Pod im Cluster über die Pod-Adresse ansprechen
könnte.

**Die Zusage gilt auch für die Infrastruktur.** Sie nur für die
Anwendungs-Namespaces einzulösen wäre die falsche Hälfte gewesen: Freien Egress
ins Heimnetz hätte damit ausgerechnet `ingress-public` behalten — der Pod, der
die Verbindungen aus der DMZ beendet, und laut Konzept genau die Komponente,
deren Rechte man unterschätzt (E2). `egress-no-lan` in
[charts/homelab-base](charts/homelab-base) begrenzt deshalb den ausgehenden
Verkehr beider Ingress-Namespaces sowie von cert-manager, step-ca, CrowdSec,
Kyverno und local-path auf „clusterintern plus öffentliches Internet".

Das ist eine `CiliumNetworkPolicy` und keine gewöhnliche `NetworkPolicy`, und
zwar aus dem Grund, der zwei Absätze weiter oben steht: Eine NetworkPolicy kann
Egress nur über `ipBlock` beschreiben, und `ipBlock` greift bei Cilium nicht auf
`host`, `remote-node` und `kube-apiserver`. Ein Default-Deny daraus würde den
Weg zur Kubernetes-API mit abschneiden und jeden Controller stillstellen.
`toEntities` ist das Gegenstück, das die Kubernetes-API nicht kennt.

Die Objekte tragen nur Egress-Regeln. Eine `CiliumNetworkPolicy` ohne
Ingress-Abschnitt schaltet die Ingress-Durchsetzung nicht ein — die Webhooks von
Kyverno und cert-manager bleiben unberührt. Das ist Absicht: Kyverno läuft mit
`failurePolicy: Fail`, ein Fehler an dieser Stelle wäre ein clusterweiter
Stillstand. Wenn nach dem Anwenden etwas nicht mehr erreichbar ist:

```bash
kubectl -n kube-system exec ds/cilium -- hubble observe --verdict DROPPED
kubectl -n traefik-public delete cnp egress-no-lan     # Notbremse
```

## CrowdSec

| Komponente | Ort | Aufgabe |
|---|---|---|
| Agent (Proxy-Logs) | Edge-VM | 404-Stürme, CVE-Scans, 401-Muster |
| Agent (App-Logs) | hier, DaemonSet | Nextcloud-Loginfehler, Paperless |
| LAPI | hier | sammelt Alarme, hält die Sperrliste |
| Firewall-Bouncer | Edge-VM | setzt nftables-Regeln |

Die LAPI gehört in den Cluster, weil die Edge die Komponente mit
Internetkontakt ist: Läge die Entscheidungsdatenbank dort, könnte ein
Angreifer die Sperrliste löschen, die ihn blockiert (E7).

Zwei Dinge, die das Konzept ausdrücklich verlangt, stehen in
[values/crowdsec.yaml.tftpl](values/crowdsec.yaml.tftpl):

- **Die eigenen Adressen werden nie gesperrt**, und zwar als Profil auf der
  LAPI statt als Whitelist im Agenten. Eine Whitelist greift nur dort, wo der
  Alarm entsteht — Alarme kommen hier aber auch von der Edge-VM, und wer die
  übernimmt, kann Alarme für beliebige IPs melden.
- **Alarme vom Edge-Agenten zählen weniger**: kürzere Sperrdauer. Der
  Schreibpfad aus der exponierten Zone in die Entscheidungsdatenbank der
  vertrauten Zone lässt sich nicht schließen, ohne die Erkennung auf der Edge
  aufzugeben — aber er lässt sich gewichten.

Der Beobachtungsmodus aus dem Konzept ist eingebaut: Der Firewall-Bouncer auf
der Edge bleibt aus, bis er ausdrücklich scharfgeschaltet wird. Ein bis zwei
Wochen `cscli alerts list` lesen, die Fehlalarme der Immich-Mobile-Clients
kennenlernen, dann erst sperren.

## Das Dashboard

[Headlamp](values/headlamp.yaml.tftpl), erreichbar unter
`https://dashboard.<domain>` — nur über `ingress-internal`, also nur aus dem
Heimnetz.

**Die Anmeldung ist die eigentliche Kontrolle, nicht die Netzgrenze.**
Headlamp fragt beim Aufruf nach einem Token und spricht anschließend mit
genau der Identität, zu der dieses Token gehört. Wer die Adresse ohne Token
aufruft, sieht nichts. Das ist der Unterschied zum Traefik-Dashboard, das in
beiden Controllern aus bleibt: Dort *wäre* „nur im LAN erreichbar" die
einzige Kontrolle.

```bash
# Der Alltagsfall: lesen. Kommt an keine Secrets.
kubectl -n headlamp create token headlamp --duration=8h

# Nur wenn geändert werden soll. Läuft nach einer Stunde ab.
kubectl -n headlamp create token headlamp-admin --duration=1h

# Ohne DNS-Eintrag zum Ausprobieren
kubectl -n headlamp port-forward svc/headlamp 8080:80
```

Der Name muss im Heimnetz auf `192.168.178.222` zeigen (AdGuard oder
Fritzbox). Aus dem Internet ist er weder auflösbar noch erreichbar.

**Warum Headlamp und nicht das Kubernetes-Dashboard oder Rancher.** Rancher
ist ein Werkzeug zur Verwaltung vieler Cluster: Der Server allein möchte 4 GB
RAM auf einem eigenen Node, bringt rund sechzig CRDs mit und setzt einen
Agenten mit `cluster-admin` in den Cluster — auf einem Node mit 4,8 GB, auf
dem noch Nextcloud, Immich und Paperless landen sollen, geht das nicht auf.
Das Kubernetes-Dashboard ist seit v7 fünf Dienste statt einem. Headlamp ist
ein Container mit rund 80 MB und läuft ohne Zugeständnis unter PodSecurity
`restricted`.

**Die Rechte kommen nicht aus dem Chart.** Es bindet seinen ServiceAccount ab
Werk an `cluster-admin`. Stattdessen legt
[charts/homelab-policies](charts/homelab-policies/templates/dashboard-rbac.yaml)
zwei ServiceAccounts an: `headlamp` mit der eingebauten Rolle `view` plus
Leserecht auf das Clusterweite (Nodes, PVs, CRDs) — unter dem läuft der Pod —
und `headlamp-admin` mit `cluster-admin`, aber ohne Token. Ein übernommener
Dashboard-Pod ist damit ein Leseleck, kein Cluster-Admin. Die Gegenprobe wird
in `verify/assert-platform.sh` tatsächlich ausprobiert:

```bash
kubectl auth can-i get secrets -A --as=system:serviceaccount:headlamp:headlamp   # no
kubectl auth can-i delete deployments -A --as=system:serviceaccount:headlamp:headlamp   # no
```

Das Dashboard hat außerdem als einziger Infrastruktur-Namespace **keinen**
Egress ins Internet (`egress-cluster-only` statt `egress-no-lan`): Ein Pod mit
clusterweitem Lesezugriff und freiem Ausgang wäre ein fertiger Abflussweg für
Clusterdaten.

### Auslastungsanzeigen: eine Reihenfolge über Modulgrenzen

`metrics_server_enabled` steht standardmäßig auf `false`, und das ist keine
Meinung, sondern eine Abhängigkeit. metrics-server braucht ein prüfbares
Serverzertifikat vom Kubelet. Das gibt es erst mit `serverTLSBootstrap` in
`vm/talos` — und das wiederum braucht einen Genehmiger für die
Zertifikatsanträge, der aus *diesem* Modul kommt. Der übliche Ausweg
`--kubelet-insecure-tls` steht bewusst nicht in
[values/metrics-server.yaml](values/metrics-server.yaml): Er wäre eine
ungeprüfte Verbindung zu der Komponente, die Auskunft über jeden Pod auf dem
Node gibt.

```bash
cd vm/talos     && terraform apply                     # noch ohne
cd k8s/platform && terraform apply                     # bringt kubelet-csr-approver
cd vm/talos     && terraform apply                     # kubelet_server_certs = true
talosctl -n 192.168.178.222 reboot
kubectl get csr                                        # nichts auf "Pending"
cd k8s/platform && terraform apply                     # metrics_server_enabled = true
kubectl top node
```

Der Genehmiger selbst hat keinen Schalter — er hängt an der Talos-Config, nicht
am Dashboard. Wer ihn abschaltet, während `kubelet_server_certs` an ist, legt
beim nächsten Zertifikatswechsel den Node lahm.

## Was noch offen ist

Ehrlicher Stand — das hier deckt nicht alles ab, was im Konzept steht:

- **Storage.** `local-path` legt PVCs auf der Systemplatte des Nodes an. Das
  ist für Postgres richtig (Datenbanken über NFS sind eine Quelle für schwer
  auffindbare Korruption), für Fotos und Dokumente nicht. Die NFS-Exporte pro
  Dienst mit `root_squash`/`all_squash` in einem eigenen Storage-Netz fehlen
  noch.
- **Backup.** Gar nichts davon ist hier. Das Konzept fordert ein Ziel, das
  Append-only *erzwingt* — und hält selbst fest, dass ein Repository auf
  demselben Unraid-Host das nicht leistet.
- **Eine CA statt zwei.** step-ca sichert die Strecke Edge → Cluster,
  cert-manager die internen Namen. Beides ließe sich mit `step-issuer`
  zusammenführen; das kostet einen weiteren Controller und ist nicht
  dringend, weil die beiden Bereiche nichts miteinander zu tun haben.
- **GitOps.** Das Konzept sieht Flux vor. Hier steht Terraform — bewusst, weil
  die Reihenfolge zwischen Node, CRDs und Policies explizit sein sollte.
  Anwendungsmanifeste (Nextcloud, Immich, Paperless) sind der natürliche
  erste Kandidat für Flux; die Namespaces und Netzgrenzen stehen dann schon.
- **Das CA-Passwort steht im Klartext in einer ConfigMap.** So arbeitet der
  Bootstrap-Job des step-certificates-Charts. Es schützt den Schlüssel auf der
  Platte, und der liegt im selben Namespace — der Gewinn wäre gering, der
  Hinweis gehört trotzdem hierher.
- **Ingress-Regeln fehlen für cert-manager und Kyverno.** Beide bekommen
  `egress-no-lan`, aber kein Default-Deny auf der Eingangsseite. Ihre Webhooks
  hängen im Admission-Pfad, Kyverno mit `failurePolicy: Fail` — eine falsche
  Regel dort legt den ganzen Cluster still, und der Gewinn wäre gering, weil
  beide ohnehin nur clusterintern erreichbar sind. Bewusst offengelassen, nicht
  übersehen.

## Betrieb

```bash
export KUBECONFIG=../../vm/talos/kubeconfig

kubectl get pods -A
kubectl -n traefik-public logs deploy/traefik-public -f
kubectl -n step-ca logs -l job-name --tail=50            # Zertifikatsausstellung
kubectl -n step-ca get cronjob ingress-cert-renew
kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli alerts list
kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli decisions list
kubectl -n kyverno get clusterpolicy
kubectl get policyreport -A                     # was Kyverno gesehen hat

# Dashboard und Metriken
kubectl -n headlamp create token headlamp --duration=8h   # Token zum Lesen
kubectl -n headlamp logs deploy/headlamp
kubectl get csr                                 # nichts auf "Pending"
kubectl -n kube-system logs -l app.kubernetes.io/name=kubelet-csr-approver
kubectl top node && kubectl top pod -A

# Zertifikat von ingress-public ansehen
kubectl -n traefik-public get secret ingress-public-tls \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject -dates -ext subjectAltName

# Nach jeder Änderung
terraform apply && verify/assert-platform.sh
```

## Aufräumen

```bash
terraform destroy
```

Nimmt auch die interne CA mit. Danach sind die Zertifikate auf der Edge-VM
wertlos — Schritt 1 bis 3 oben müssen dann erneut durchlaufen werden, mit
einem neuen Fingerprint.
