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
| 3 | Kyverno | erzwingt `ingressClassName: public` nur in gekennzeichneten Namespaces |
| 4 | `ingress-public`, `ingress-internal` | zwei Traefik-Instanzen, an je eine Adresse gebunden |
| 5 | CrowdSec | LAPI und Agent für die Anwendungslogs |
| 6 | `homelab-policies` (lokales Chart) | Policies, die Router zu LAPI und step-ca, ClusterIssuer |

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

**Das Serverzertifikat von `ingress-public`** holt sich ein Init-Container mit
`step-cli` bei step-ca und erneuert es mit einem Sidecar — derselbe
Mechanismus wie auf der Edge-VM, mit denselben 24 Stunden Laufzeit (E5).
Erneuert wird über mTLS mit dem noch gültigen Zertifikat; nach jeder
Erneuerung wird die dynamische Konfiguration angefasst, weil Traefik
Zertifikatsdateien nur beim Laden der Konfiguration liest.

Der Unterschied zur Edge: Hier liegt das Provisioner-Passwort im Pod. Das ist
eine bewusste Abweichung — `ingress-public` steht in der vertrauten Zone, und
der Preis wäre sonst ein Token von Hand bei jedem Pod-Neustart. Wer die
Abweichung nicht will, entfernt das Secret aus [main.tf](main.tf) und
bootstrappt den Pod wie die Edge-VM.

## Die zwei Ingress-Controller

Trennung nach Erreichbarkeit statt nach Konfiguration (E6):

| | `ingress-public` | `ingress-internal` |
|---|---|---|
| Bindung | `10.10.20.3:443` | `192.168.178.21:80,443` |
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

## Betrieb

```bash
export KUBECONFIG=../../vm/talos/kubeconfig

kubectl get pods -A
kubectl -n traefik-public logs deploy/traefik-public -f
kubectl -n traefik-public logs deploy/traefik-public -c pki-renew   # Zertifikatserneuerung
kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli alerts list
kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli decisions list
kubectl -n kyverno get clusterpolicy
kubectl get policyreport -A                     # was Kyverno gesehen hat

# Zertifikat von ingress-public ansehen
kubectl -n traefik-public exec deploy/traefik-public -c pki-renew -- \
  step certificate inspect /pki/tls.crt --short

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
