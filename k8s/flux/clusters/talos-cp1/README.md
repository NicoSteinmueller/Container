# Wurzel-Verzeichnis für Flux

Was hier liegt, rollt Flux automatisch aus - dies ist der `sync.path` der
FluxInstance aus `../../main.tf`.

## Egress: wer aus dem Cluster heraus darf

Eingehend ist die Trennung über Zonen und `default-deny-ingress` je Namespace
geregelt. Die Gegenrichtung war es lange nicht — ohne Egress-Regel erreicht
jeder Pod das ganze Heimnetz, den Unraid-Host eingeschlossen. Nachgemessen:

```bash
kubectl -n crowdsec exec ds/crowdsec-agent -- nc -z 192.168.178.3 80
```

Jeder Namespace mit eigenen Pods trägt deshalb eine `CiliumNetworkPolicy` mit
`endpointSelector: {}` und einem `egress`-Block — das allein schaltet
Default-Deny für die ausgehende Richtung. Die Begründung je Regel steht in der
jeweiligen Datei.

| Namespace            | Darf hinaus zu                                              |
|----------------------|-------------------------------------------------------------|
| `crowdsec`           | CoreDNS · LAPI `:8080` · Internet `:443` (CAPI, Hub)         |
| `headlamp`           | CoreDNS · kube-apiserver `:6443`                             |
| `reloader`           | CoreDNS · kube-apiserver `:6443`                             |
| `local-path-storage` | CoreDNS · kube-apiserver `:6443`                             |
| `cert-manager`       | CoreDNS · kube-apiserver `:6443` — kein Internet, die CA ist intern |
| `cnpg-system`        | CoreDNS · kube-apiserver `:6443` · Instanzen `:5432`/`:8000` |
| `monitoring`         | CoreDNS · kube-apiserver `:6443` · Kubelet `:10250` · Scrape-Ziele je Namespace · Sync-Job zusätzlich Internet `:443` |
| `traefik-internal`   | + headlamp `:4466` · whoami `:80` · Internet `:443`/`:53`    |
| `traefik-public`     | + LAPI · whoami · Internet `:443`/`:53`                      |
| `whoami`             | CoreDNS (`kind: NetworkPolicy`, aus dem Chart)               |

Ins Heimnetz darf keiner: Die Internet-Regeln sind `toCIDRSet` auf `0.0.0.0/0`
mit RFC 1918 und `169.254.0.0/16` unter `except`.

**Zwei Namespaces haben bewusst keine** — beide, weil die Policy dort nicht
wirken *könnte*, nicht weil sie unerwünscht wäre:

- **`csi-driver-nfs`** — beide Pods laufen auf hostNetwork und tragen damit die
  Identität des Nodes. Keine NetworkPolicy greift auf sie. Begründung in
  [nfs-storage.yaml](nfs-storage.yaml).
- **`kube-system`** — sechs von neun Pods ebenfalls hostNetwork (Cilium, Envoy,
  Operator und die drei Static Pods). Adressierbar blieben CoreDNS und
  metrics-server. CoreDNS braucht den Resolver im LAN (`dns_servers` aus
  `vm/talos/terraform.tfvars`) — eine Regel dafür koppelt eine Flux-Datei an
  die tfvars, und ein Fehler nimmt die clusterweite Namensauflösung mit. Der
  Gewinn steht dazu in keinem Verhältnis.

```bash
# Gegenprobe nach dem Rollout - erwartet: kein Durchkommen mehr
kubectl -n crowdsec exec ds/crowdsec-agent -- nc -z -w3 192.168.178.3 80
kubectl -n kube-system exec ds/cilium -- \
  hubble observe --from-namespace crowdsec --verdict DROPPED --last 50
```

## Pod Security: welcher Namespace was darf

Ohne `pod-security.kubernetes.io/enforce`-Label gilt **`privileged`** — ein Pod
dort dürfte privilegiert laufen, Host-Namespaces betreten und hostPath mounten.
Jeder Namespace trägt seine Stufe deshalb ausdrücklich; die, die Kubernetes
selbst anlegt, bekommen sie über [namespaces.yaml](namespaces.yaml).

| Stufe | Namespaces | Warum |
|---|---|---|
| `restricted` | `headlamp`, `reloader`, `traefik-internal`, `traefik-public`, `whoami`, `cnpg-system`, `cert-manager` | Brauchen nichts davon |
| `restricted` | `default`, `kube-public`, `kube-node-lease` | Leer, und sollen es bleiben |
| `privileged` | `crowdsec` | Agent liest Container-Logs per hostPath |
| `privileged` | `csi-driver-nfs` | `mount(8)` im Host-Namespace, Bidirectional Mount Propagation |
| `privileged` | `local-path-storage` | Helfer-Pods legen Verzeichnisse auf der Host-Platte an |
| `privileged` | `monitoring` | node-exporter: hostNetwork, hostPID, hostPath auf `/proc`, `/sys`, `/` |
| *(keine)* | `kube-system`, `flux-system`, `cilium-secrets` | siehe unten |

**hostPath ist bereits ab `baseline` ein Verstoß**, nicht erst ab `restricted`.
Das ist der Grund, warum die drei mittleren Zeilen auf `privileged` stehen und
nicht eine Stufe tiefer — nachgemessen:

```bash
kubectl label --dry-run=server --overwrite ns crowdsec \
  pod-security.kubernetes.io/enforce=baseline
# Warning: crowdsec-agent-…: hostPath volumes
```

`warn` und `audit` stehen dort trotzdem auf `baseline`: Jede *andere*
Abweichung taucht weiterhin als Warnung auf, nur der hostPath ist die Ausnahme.

**`default` ist der Fall, auf den es ankommt.** Er ist leer — aber ein Manifest
ohne `namespace:` landet genau hier, und das ist die Sorte Fehler, die niemand
absichtlich macht. Nebenwirkung: `kubectl run` und `kubectl debug` ohne
securityContext werden dort jetzt abgelehnt — für einen schnellen Testpod
lästig, und genau so gemeint.

**Drei bleiben bewusst ohne Stufe:**

- **`kube-system`** — Cilium läuft dort mit `privileged: true` (mount-bpf-fs)
  und einem Capability-Satz, den `baseline` ablehnt. Eine Stufe wäre hier kein
  Zugewinn, sondern ein Ausfall des CNI.
- **`flux-system`** — bewusst offen, damit die Controller anwenden dürfen, was
  im Repo steht.
- **`cilium-secrets`** — trägt `helm.sh/chart=cilium-1.20.1`, kommt also aus dem
  Inline-Manifest der Talos-Machine-Config und nicht aus Flux. Von hier aus
  bearbeitet, wären zwei Schreiber auf demselben Objekt. Pods laufen dort keine.

> Die drei Namespaces in `namespaces.yaml` tragen
> `kustomize.toolkit.fluxcd.io/prune: disabled`. Sie existierten vor diesem Repo
> und sollen es überleben — ohne die Annotation würde Flux sie beim Entfernen
> der Datei einsammeln, und ein Namespace nimmt beim Löschen alles mit, was
> darin liegt.

## Woher die Charts kommen

Jede Fremdquelle in diesem Verzeichnis ist unveränderlich gepinnt. Der Grund
steht in einem Satz: `kustomize-controller` und `helm-controller` sind an
`cluster-admin` gebunden (`multitenant: false`, ein Autor — siehe
[../../README.md](../../README.md)). Was hier als Chart hereinkommt, wird also
mit den höchsten Rechten des Clusters gerendert und angewendet. Eine bewegliche
Quelle ist damit gleichbedeutend mit fremdem Code als Cluster-Admin.

| Quelle | Pinning |
|---|---|
| `local-path-provisioner` | GitRepository auf **Tag** `v0.0.37` |
| `csi-driver-nfs` | GitRepository auf **Tag** `v4.13.4`, Chart aus `charts/v4.13.4/` |
| Traefik, CrowdSec, Headlamp, metrics-server, Reloader, CloudNativePG, cert-manager, VictoriaMetrics | HelmRepository über HTTPS, Chart-Version exakt gepinnt |
| Grafana-Dashboards und Alarmregeln | **nicht gepinnt** — ein Sync-Job holt sie beim Deployen aus dem Netz, siehe [monitoring.yaml](monitoring.yaml) |
| Container-Images | Tag, teils zusätzlich Digest |


Bei `csi-driver-nfs` kam in beiden Varianten dazu, dass die frühere
`HelmRepository` auf `…/master/charts` zeigte und die Version `4.13.4` dort auf
`…/release-4.12/charts/latest/…` auflöste — ein wanderndes Verzeichnis auf
einem wandernden Branch. Die gepinnte Versionsnummer benannte einen Eintrag im
Index, nicht dessen Inhalt.

Beide Tags hebt jetzt der eingebaute `flux`-Manager. Der `customManager` in
[renovate.json5](../../../../renovate.json5), der die Commit-Zeilen nachzog, ist
damit entfallen — er hätte auf nichts mehr gepasst, und eine Regel, die
aussieht als täte sie etwas, ist schlimmer als keine.

> **Bei einem `csi-driver-nfs`-Update ändern sich drei Zeilen**: der `tag:`,
> der `chart:`-Pfad (`./charts/v4.13.4/…`) *und* der `ignore:`-Pfad. Renovate
> hebt nur den ersten. Werden die anderen vergessen, findet Flux das Chart
> nicht — ein lauter Fehler, kein stiller.

**Was offen bleibt**, weil es eine Entscheidung oder einen Schlüssel braucht,
den dieses Repo nicht hat:

- **Keine Signaturprüfung** (`spec.verify`) auf den GitRepositories. Sie setzt
  GPG-signierte Commits und ein Secret mit dem öffentlichen Keyring voraus —
  eine Umstellung der eigenen Arbeitsweise, nicht eine Zeile Manifest. Solange
  sie fehlt, ist ein kompromittierter GitHub-Zugang oder ein abgeflossenes PAT
  gleichbedeutend mit Cluster-Admin.
- **Kein `serviceAccountName`** an Kustomizations und HelmReleases. Das ist der
  Weg, `cluster-admin` loszuwerden; er verlangt je Kustomization eine eigene
  Rolle und ist bei einem Autor bewusst nicht gegangen worden.

## `whoami.yaml`

`HelmRelease` auf das lokale Chart `k8s/whoami/chart` (Deployment, Service,
NetworkPolicy, Namespace, Ingress). `sourceRef` zeigt auf die
`GitRepository flux-system` - kein zweites Source-Objekt nötig.

`valuesFiles` wählt die Umgebung; `values-prod.yaml` setzt seit
[ingress-internal.yaml](ingress-internal.yaml) `service.type: ClusterIP` und
einen Ingress auf `ingressClassName: internal`. Der NodePort `30083` ist damit
weg. Werte pro Umgebung: `k8s/whoami/README.md`.

```bash
kubectl -n flux-system get helmrelease whoami
kubectl -n whoami get pods,svc,ingress
curl -k https://whoami.k8s.nico-steinmueller.de
```

## `secrets.yaml`

Die zweite Git-Quelle: `GitRepository` auf `homelab-secrets` im Gitea plus die
`Kustomization`, die sie anwendet. Der `decryption`-Block darin ist die
eigentliche Zeile — ohne ihn landete `ENC[AES256_GCM,...]` wörtlich als Wert im
Cluster, und die Kustomization bliebe dabei grün.

Warum ein zweites Repo statt einer Datei hier: Dieses geht öffentlich nach
GitHub, und auch Ciphertext soll dort nicht liegen. Begründung im Kopf der
Datei, Umgang damit in [../../README.md](../../README.md#secrets).

```bash
kubectl -n flux-system get gitrepository homelab-secrets
kubectl -n flux-system get kustomization homelab-secrets

# Beweisfall - erwartet wird "entschluesselt":
kubectl -n flux-system get secret sops-smoketest \
  -o jsonpath='{.data.probe}' | base64 -d; echo
```

## `reloader.yaml`

Startet neu, was ein geändertes Secret benutzt — sonst arbeitet ein Pod nach
einer Rotation bis zu seinem nächsten Start mit dem alten Wert weiter. Fremder
Chart, deshalb eine eigene `HelmRepository`.

Wen er anfasst, regelt er selbst: `autoReloadAll: true` — innerhalb seines
Blickfelds gilt jeder Workload als annotiert. Vorher setzte Kyverno die
Annotation `reloader.stakater.com/auto` cluster-weit; mit dem Plattform-Stack
fiel Kyverno weg, und Reloader lief eine Zeit lang wirkungslos. Dieselbe Regel,
ein Controller weniger.

Das Blickfeld ist eine Namespace-Liste und nicht der ganze Cluster
(`watchGlobally: false` plus `namespaces`): `crowdsec`, `traefik-internal`,
`traefik-public` — dort und nur dort hält ein laufender Prozess ein Secret aus
`homelab-secrets`. Das Chart legt daraufhin Role und RoleBinding je Namespace
an und **keine ClusterRole**. Der Unterschied ist nicht kosmetisch: Cluster-weit
bekam Reloader `update`/`patch` auf Deployments, DaemonSets und StatefulSets in
jedem Namespace, `kube-system` eingeschlossen. Begründung je Namespace und die
Gegenrechnung stehen in [reloader.yaml](reloader.yaml).

> **Ein neuer Dienst mit Secret gehört in diese Liste.** Sonst läuft er nach
> einer Rotation still mit dem alten Wert weiter — er läuft ja.

```bash
# Gegenprobe, dass nichts cluster-weit übrig ist:
kubectl get clusterrole,clusterrolebinding | grep reloader   # erwartet: leer
kubectl get role,rolebinding -A | grep reloader
```

```bash
kubectl -n reloader get pods
kubectl -n reloader logs deploy/reloader-reloader | tail
```

## `headlamp.yaml`, `metrics-server.yaml`

Beide Charts kommen aus fremden Helm-Repositories - `chart.spec.sourceRef`
braucht deshalb je eine eigene `HelmRepository` statt der `GitRepository`.

`headlamp.yaml` bringt Namespace und RBAC als eigene Manifeste mit (PodSecurity
`restricted`, ServiceAccount `headlamp` nur lesend, `headlamp-admin` mit
`cluster-admin` ohne Pod und Token) - das Chart selbst würde den Namespace
unbeschriftet anlegen und seinen ServiceAccount an `cluster-admin` binden.
Begründungen stehen als Kommentare in der Datei.

`metrics-server.yaml` liefert die Auslastungsanzeigen, läuft in `kube-system`
mit `--kubelet-insecure-tls` (siehe Kommentare dort).

Headlamp hängt seit [ingress-internal.yaml](ingress-internal.yaml) an
`https://dashboard.k8s.nico-steinmueller.de`, nicht mehr am NodePort `30080`.
Das Token, das man beim Aufruf einfügt, ging über den NodePort im Klartext
durchs LAN; jetzt nicht mehr.

Erreichbar ist das Dashboard nur über den Controller - die NetworkPolicy im
Namespace lässt sonst niemanden an den Pod. Anmeldung per Token:

```bash
kubectl -n headlamp create token headlamp --duration=8h        # Lesen
kubectl -n headlamp create token headlamp-admin --duration=1h  # Ändern
kubectl -n flux-system get helmrelease headlamp metrics-server
```

## `lb-ipam.yaml`

Die LAN-Adressen des Clusters: welche es gibt (`CiliumLoadBalancerIPPool`,
`.231`–`.232`) und wie das Netz von ihnen erfährt
(`CiliumL2AnnouncementPolicy` auf `enp1s0`).

Zwei Teile, die man auseinanderhalten muss — die Verwechslung ist der
häufigste Fehler an dieser Stelle:

| | was es tut | wo es eingeschaltet wird |
|---|---|---|
| **LB-IPAM** | *vergibt* eine Adresse an einen Service | nirgends — es genügt, dass ein IPPool existiert |
| **L2-Announcement** | *kündigt* sie per Gratuitous ARP im Netz an | `l2announcements.enabled` in [cilium.yaml.tftpl](../../../../vm/talos/values/cilium.yaml.tftpl) |

Fehlt der zweite Teil, sieht der Service **gesund aus** — `EXTERNAL-IP` steht
da — und ist trotzdem für niemanden erreichbar. Die aussagekräftige Gegenprobe
ist deshalb nicht der Service, sondern die Lease:

```bash
kubectl -n kube-system get lease | grep l2announce
kubectl get ciliumloadbalancerippools,ciliuml2announcementpolicies
```

Der Wert in den Cilium-Werten setzt zweierlei: das Agent-Flag
`enable-l2-announcements` **und** die RBAC-Regeln auf
`coordination.k8s.io/leases`. Wer die Abkürzung über
`kubectl patch cm cilium-config` nimmt, bekommt nur das Flag — und damit einen
Agent, der ankündigen will und nicht darf:

```
leases.coordination.k8s.io "cilium-l2announce-..." is forbidden
```

Dass Gratuitous ARP für eine Zusatzadresse über das macvtap-Interface des
Nodes überhaupt durchgeht, war die offene Frage der ganzen Umstellung. Sie ist
nachgemessen: Vom Unraid-Host aus trägt `.231` dieselbe MAC wie `.230`.
Vorgehen samt der beiden Fallen, die ein falsches Negativ liefern, in
[../../../INBETRIEBNAHME.md](../../../INBETRIEBNAHME.md), Schritt 4.

Die Zuordnung Service → Adresse steht **nicht** hier, sondern als Annotation
`lbipam.cilium.io/ips` am jeweiligen Service. Ohne sie wäre sie die
Reihenfolge der Vergabe — und ein Neustart könnte die beiden Ingress-Adressen
tauschen, mitten in einer bestehenden Portfreigabe.

Die beiden CRs tragen verschiedene apiVersions: Beim IPPool ist `cilium.io/v2`
die Storage-Version (`v2alpha1` quittiert das Apply mit einer
Deprecation-Warnung), die L2-Policy kennt in Cilium 1.20.1 **kein** `v2`. Beim
Cilium-Update mitprüfen.

## `ingress-internal.yaml`

Der erste Ingress-Controller dieses Clusters: Namespace, IngressClass
`internal`, NetworkPolicies und die Traefik-Release. Vorher war jeder Dienst
nur über einen NodePort und per HTTP erreichbar.

Erreichbar ausschließlich aus dem Heimnetz. Der zweite Controller für das
Internet (`ingress-public`, eigene LoadBalancer-Adresse) fehlt weiterhin —
deshalb legt die Datei auch nur **eine** Klasse an, nicht das Paar
`public`/`internal`. Eine Klasse ohne Controller wäre eine Falle: Ein Ingress
mit `ingressClassName: public` würde angenommen und nie bedient.

### hostPort statt hostNetwork

Der frühere Plattform-Stack fuhr beide Controller mit `hostNetwork` und band
sie über `hostIP` an je eine Node-Adresse. Das kostete den Sysctl
`net.ipv4.ip_unprivileged_port_start=0` auf dem Node, weil Traefik als UID
65532 sonst die Ports 80 und 443 nicht binden darf.

Beides ist hier weg, und die Kette dahin steht ausführlich in der Datei. Kurz:
Der Node hat heute **ein** Bein und dieser Cluster **einen** Controller. Damit
entfällt der Grund für `hostIP` — und ohne `hostIP` der für `hostNetwork`, und
ohne `hostNetwork` der für den Sysctl. Traefik bindet 8000/8443 im eigenen
Pod-Netz, wo es kein Privileg braucht, und Cilium bildet Node:80/443 darauf ab.
Das kann es, weil kube-proxy durch Cilium ersetzt ist.

**Die Stelle, an der das zurückgedreht werden muss,** ist der Bau von
`ingress-public`: Zwei Controller auf einem Node brauchen wieder je eine eigene
Adresse, also `hostIP`, also `hostNetwork`, also den Sysctl.

### Was den Zugang begrenzt

| | wodurch |
|---|---|
| Von außen nur aus dem LAN | NetworkPolicy `allow-from-lan` (`ipBlock` auf das Heimnetz) |
| An die Anwendungen nur über den Controller | `default-deny-ingress` je Namespace plus eine Regel auf `traefik-internal` |
| Secrets nur in drei Namespaces | eigene RBAC statt der des Charts, siehe unten |

Der letzte Punkt ist die Bremse, die man beim nächsten Dienst spürt: Ein neuer
Namespace muss an **drei** Stellen stehen — in
`providers.kubernetesIngress.namespaces`, in `providers.kubernetesCRD.namespaces`
und als RoleBinding. Fehlt die Bindung, sieht Traefik den Namespace nicht;
fehlt er in den Listen, schaut Traefik nicht hin.

### RBAC von Hand, und warum

`rbac.namespaced: true` wäre der naheliegende Weg — Role statt ClusterRole,
Secrets nur in den gelisteten Namespaces. Der Chart koppelt daran aber ein
zweites Verhalten, und das macht den Ingress unbrauchbar:

```
rbac.namespaced: true  ->  --providers.kubernetesingress.disableClusterScopeResources=true
```

Mit diesem Flag holt Traefik die Liste der IngressClasses gar nicht erst. Und
weil `shouldProcessIngress` bei gesetztem `spec.ingressClassName`
**ausschließlich** gegen diese Liste prüft, fällt jeder Ingress durch — ohne
Logzeile, mit 404 am Controller. Übrig bliebe die seit Traefik v2 deprecated
Annotation `kubernetes.io/ingress.class`, und die greift nur, wenn
`ingressClassName` ganz fehlt.

Deshalb `rbac.enabled: false`: Dann erzeugt der Chart keine RBAC — und setzt
das Flag auch nicht, denn es hängt allein an `rbac.namespaced`. Die Rechte
stehen stattdessen als eigene Objekte in der Datei, aufgeteilt nach dem,
worauf es ankommt:

| | Rechte |
|---|---|
| ClusterRole `traefik-internal-cluster` | `nodes`, `namespaces`, `ingressclasses` — keine Geheimnisse |
| ClusterRole `traefik-internal-namespaced` | der Rest, **inkl. Secrets** — gebunden nur per RoleBinding je Namespace |

Die zweite ClusterRole wird nirgends clusterweit gebunden. Eine RoleBinding
darf eine ClusterRole referenzieren, und die Rechte gelten dann nur in ihrem
Namespace — das spart dreimal dieselbe Regelliste. Die Sicherheitszusage von
namespaced RBAC bleibt damit erhalten: Wer den Ingress übernimmt, bekommt
nicht die Secrets des ganzen Clusters dazu.

Der Preis, ehrlich benannt: Diese Regeln spiegeln, was sonst der Chart pflegt
(`templates/rbac/role.yaml`, hier aus 41.3.0 übernommen). Ändert ein
Traefik-Update die nötigen Rechte, muss das hier nachziehen — sichtbar, weil
Traefik dann RBAC-Fehler protokolliert.

Die RoleBindings heißen bewusst `traefik-internal-namespaced` und nicht wie
der Chart `traefik-internal`: `roleRef` ist unveränderlich, und wo schon eine
Bindung dieses Namens auf eine *Role* zeigt, scheitert jedes Apply mit
`cannot change roleRef`.

### Das Dashboard

Erreichbar unter `https://traefik.k8s.nico-steinmueller.de` — **mit Passwort**.

Es war lange bewusst aus: Traefiks Dashboard kennt selbst keine
Authentifizierung, und „nur im LAN erreichbar“ ist keine. Wer es öffnet, sieht
jeden Router, jeden Service und jede Middleware — also eine Liste dessen, was
es in diesem Cluster überhaupt zu erreichen gibt. Aufgemacht ist es deshalb nur
zusammen mit einer BasicAuth-Middleware:

| Objekt | wo |
|---|---|
| IngressRoute `traefik-internal-dashboard` | vom Chart, `ingressRoute.dashboard` in [ingress-internal.yaml](ingress-internal.yaml) |
| Middleware `traefik-dashboard-auth` | eigenes Manifest in derselben Datei |
| Middleware `traefik-dashboard-root` | dieselbe Datei — leitet `/` auf `/dashboard/` |
| Secret `traefik-dashboard-auth` | SOPS-verschlüsselt in `homelab-secrets`, Benutzer `nico` |

Die Match-Regel ist bewusst nur `Host(...)` statt der Chart-Voreinstellung
``PathPrefix(`/dashboard`) || PathPrefix(`/api`)``: Der Hostname gehört allein
diesem Dashboard, und mit der Voreinstellung wäre ausgerechnet die eingetippte
Adresse ohne Pfad ein 404.

Einen zweiten, ungeschützten Weg zum Dashboard gibt es **nicht**. Der
Entrypoint `traefik` (Port 8080) trägt nur `/ping` für die Kubelet-Probes:
`--api.dashboard=true` legt allein den Handler `api@internal` an, bedient wird
er ausschließlich von einem Router. Auf 8080 läge die API erst mit
`--api.insecure=true` („Activate API directly on the entryPoint named
traefik"), und dieses Flag setzt der Chart nicht.

Passwort wechseln:

```bash
python3 -c 'import bcrypt,getpass; print("nico:"+bcrypt.hashpw(getpass.getpass().encode(), bcrypt.gensalt(rounds=12)).decode())'
sops clusters/talos-cp1/traefik-dashboard-auth.sops.yaml   # in homelab-secrets
```

Traefik liest das Secret über seinen Informer — der Wechsel gilt sofort, ohne
Pod-Neustart.

### Das Zertifikat

Ein **Wildcard von Let's Encrypt** für `*.k8s.nico-steinmueller.de`, per
DNS-01 über IONOS — von Traefik selbst geholt, nicht von cert-manager. Port 80
leitet dauerhaft auf 443 um.

Drei Entscheidungen stecken darin:

**Traefik statt cert-manager**, weil cert-manager keinen IONOS-Solver hat.
Eingebaut sind nur Akamai, AzureDNS, CloudDNS, Cloudflare, DigitalOcean,
Route53, RFC2136 und acmeDNS. Für IONOS bräuchte es einen Webhook eines
Drittanbieters — ein zusätzlich zu wartender Controller, der den Zonen-Token
bekäme. Traefik bringt lego mit, und lego kennt IONOS. Es ist derselbe Weg,
den der Traefik-Container auf dem Unraid-Host schon geht.

**Wildcard statt Zertifikat je Name**, wegen Certificate Transparency: Jedes
von Let's Encrypt ausgestellte Zertifikat landet in öffentlichen Logs. Einzeln
ausgestellt stünde dort jeder Dienstname — eine Landkarte des Heimnetzes für
jeden, der die Domain kennt. Beim Wildcard steht dort nur, dass es eine
`k8s.`-Zone gibt. Dazu ein Antrag statt einem pro Dienst.

**Let's Encrypt statt eigener CA**, weil jedes Gerät ihr ab Werk vertraut. Eine
eigene Wurzel müsste auf Rechner, Handy und Tablet einzeln installiert werden —
und wer das nicht tut, hat die Warnung nur ausgetauscht.

Das Zertifikat hängt am **Entrypoint**, nicht an den Ingress-Objekten. Ein
neuer Dienst braucht damit keinen `tls:`-Block und kein eigenes Secret; er ist
mit seinem Namen abgedeckt.

> **Der Resolver steht auf dem Produktivverzeichnis.** Vorher war es Staging —
> zum Ausprobieren, weil die Rate Limits hart sind: fünf fehlgeschlagene
> Validierungen je Konto und Hostname pro Stunde, und ein falscher API-Key
> verbraucht die in Minuten. Wer an der DNS-01-Challenge etwas ändert, probiert
> das wieder in Staging aus.
>
> **Beim Umstellen muss `acme.json` weg** — in beide Richtungen. Es trägt das
> ausgestellte Zertifikat *und* die Registrierungs-URI des ACME-Kontos, beides
> gehört zum jeweiligen Verzeichnis, und Traefik verwirft es nicht von allein:
> Das alte Zertifikat ist gültig, also wird es weiter ausgeliefert (die
> Browser-Warnung bleibt, und es sieht aus, als sei nichts passiert), und das
> Staging-Konto quittiert das Produktivverzeichnis mit `account does not exist`.
>
> ```bash
> kubectl -n traefik-internal exec deploy/traefik-internal -- rm -f /data/acme.json
> kubectl -n traefik-internal rollout restart deploy/traefik-internal
> kubectl -n traefik-internal logs -f deploy/traefik-internal | grep -i acme
> ```
>
> Danach zieht die Warnung im Browser weg — und `curl` braucht kein `-k` mehr.

### Der API-Key

Liegt SOPS-verschlüsselt als `traefik-ionos` in `homelab-secrets`, nicht hier —
dieses Repo geht öffentlich nach GitHub. lego liest ihn ausschließlich aus der
Umgebung, deshalb `env` und keine Datei.

### Voraussetzung im Heimnetz

Nicht im Repo abgebildet: Die Hostnamen müssen **nur intern** auf die
LAN-Adresse des Nodes zeigen (AdGuard oder Fritzbox), nicht über DynDNS.

```
dashboard.k8s.nico-steinmueller.de  ->  192.168.178.230
traefik.k8s.nico-steinmueller.de    ->  192.168.178.230
whoami.k8s.nico-steinmueller.de     ->  192.168.178.230
```

Die eigene Zone `k8s.` ist dabei der Punkt: Die Dienste auf dem Unraid-Host
liegen unter `*.local.nico-steinmueller.de`, und ein Wildcard-Eintrag dorthin
kann diese Namen nicht mehr einfangen. Am Namen ist damit ablesbar, wo ein
Dienst läuft — und der Umzug eines Dienstes vom Host in den Cluster ist ein
sichtbarer Namenswechsel statt einer stillen Umleitung.

### Gegenproben

```bash
kubectl -n traefik-internal get pods
kubectl get ingressclass
kubectl get ingress -A                 # ADDRESS bleibt leer, siehe unten

# Der Beweisfall - der Weg über den Controller:
curl -k https://whoami.k8s.nico-steinmueller.de

# Das Dashboard: ohne Passwort 401, mit Passwort die Oberfläche.
curl -k -o /dev/null -w '%{http_code}\n' https://traefik.k8s.nico-steinmueller.de/dashboard/
curl -k -u nico https://traefik.k8s.nico-steinmueller.de/api/overview

# Und die Gegenrichtung: der alte NodePort ist zu.
curl --max-time 5 http://192.168.178.230:30083 || echo "zu, wie erwartet"
```

`kubectl get ingress` zeigt keine ADDRESS. Das ist kein Fehler: Der Controller
läuft ohne eigenen Service (`service.enabled: false`), und das Chart trägt die
Adresse nur aus einem solchen nach.

Antwortet der Ingress gar nicht, ist die NetworkPolicy die erste Stelle:

```bash
kubectl -n traefik-internal logs deploy/traefik-internal | tail
kubectl -n kube-system exec ds/cilium -- hubble observe --last 200 --type drop
kubectl -n traefik-internal delete networkpolicy allow-from-lan   # Notbremse
```

## `local-path.yaml`, `nfs-storage.yaml`

Der Speicher des Clusters, aufgeteilt nach **Zugriffsmuster**:

| | `local-path` (Default) | `nfs-unraid` |
|---|---|---|
| wofür | fsync und Locking: DBs, Indizes, Queues | Bestände: Medien, Uploads, Backups |
| liegt auf | zweiter Disk der VM, `/var/mnt/local-path` | Unraid-Shares über NFSv4.1 |
| Zugriff | `ReadWriteOnce`, an einen Node gebunden | `ReadWriteMany` |
| beim PVC-Löschen | `Retain` — Verzeichnis bleibt | `onDelete: retain` — Verzeichnis bleibt |

Vor diesen Dateien hatte der Cluster **keine** StorageClass — `kubectl get sc`
kam leer zurück, und jeder Chart, der einen PVC ohne `storageClassName` anlegt,
wäre auf `Pending` stehen geblieben.

Der Grund für die Aufteilung ist nicht Durchsatz. Physisch ist beides dieselbe
SSD: Die qcow2-Dateien der VM liegen auf `/mnt/cache/domains`, also auf dem
Unraid-Cache, auf den ein NFS-Mount ebenfalls zeigen würde. Der Unterschied ist
der Weg dorthin — und was er mit der Semantik macht. Jeder Commit einer
Datenbank ist ein `fsync`, und über NFS geht jeder einzelne davon durch den
Netzwerk-Stack. Dazu bleiben nach einem Neustart des NFS-Servers stale locks
zurück; SQLite rät von NFS ausdrücklich ab. Und `hard` — für Mediendaten
richtig — heißt hier, dass eine Datenbank bei einer Störung *hängt*, statt
abzustürzen.

Deshalb ist `local-path` die Default-Klasse: Ein Chart, der nichts angibt, hat
meistens etwas mit fsync vor. Wer NFS will, schreibt `storageClassName:
nfs-unraid` hin. Die Default-Annotation steht an genau **einer** Stelle — zwei
Default-Klassen wären kein Fehler, den Kubernetes meldet, es wählt dann
willkürlich aus.

### `local-path.yaml`

`local-path-provisioner` von Rancher auf der zweiten Disk der VM. Der Chart
kommt aus einer **`GitRepository`** statt einer `HelmRepository`: Rancher
veröffentlicht ihn nur im Git,  `ref.tag` statt Branch, damit Flux nicht 
jede Änderung nachzieht.

Der Pfad `/var/mnt/local-path` ist nicht frei gewählt: Talos mountet User-Volumes
immer unter `/var/mnt/<name>`. Er muss mit dem Volume-Namen in
[vm/talos/patches/uservolume.yaml.tftpl](../../../../vm/talos/patches/uservolume.yaml.tftpl)
zusammenpassen — beide Stellen tragen einen Kommentar darauf.

`volumeBindingMode: WaitForFirstConsumer` ist bei lokalem Speicher keine
Feinheit: Das Volume ist ein Verzeichnis auf genau einem Node. Auf einem
Ein-Node-Cluster fällt eine falsche Einstellung nicht auf, beim zweiten Node
sofort.

**Kein Backup.** Diese Disk verschwindet mit der VM und mit `tofu destroy`.
Ein Sicherungsweg aus dem Cluster heraus steht noch aus; wenn er kommt, gehört
er nach Kopia auf dem Unraid-Host — bei Datenbanken als Dump und nicht als
Dateikopie.

### `nfs-storage.yaml`

`csi-driver-nfs` plus die StorageClass `nfs-unraid` auf den Share `k8s` des
Unraid-Hosts.

**Ein** Mechanismus für alles Dauerhafte — plus eine Brücke, die wieder
verschwindet:

- **dynamisch über `nfs-unraid`** (nicht die Default-Klasse — die ist
  `local-path`, siehe oben; wer NFS will, schreibt `storageClassName` hin).
  Der Treiber legt je PVC ein Verzeichnis `<namespace>/<pvc-name>` unter
  `/mnt/user/k8s` an. Für **alles**, was dauerhaft auf dem Array liegen soll:
  Dumps ebenso wie Nutzerdateien und Medien.

  Dass das auch für Bestände trägt, deren Verlust wehtut, hängt an
  `onDelete: retain`: Beim Löschen eines PVC passiert mit dem Verzeichnis
  nichts. Und weil der Pfad ausschließlich aus Namespace und PVC-Namen
  entsteht, findet ein später neu angelegtes PVC gleichen Namens seine Daten
  wieder. Statisch gebundene PVs braucht es dafür nicht — ein Weg, ein Muster,
  ein Pfad.

### Voraussetzung auf dem Unraid-Host

Nicht im Repo abgebildet und von Hand zu setzen — NFS ist dort ab Werk aus
(`shareNFSEnabled="no"`, `/etc/exports` leer, Port 2049 zu):

1. **Array stoppen.** *Settings → NFS* ist bei laufendem Array gesperrt.
2. *Settings → NFS* → **Enable NFS = Yes**, Array wieder starten.
3. Share `k8s` anlegen, falls noch nicht vorhanden — das Ziel jedes PVC.
4. Unter *Shares → k8s → NFS Security Settings*: **Export = Yes**,
   Rule auf die Node-Adresse:

   ```
   192.168.178.230(sec=sys,rw,no_root_squash)
   ```

   für den Share `k8s` — den einzigen, den der Cluster mountet.

Die Regel steht auf der **Node-Adresse**, nicht auf dem Pod-CIDR: Gemountet
wird nicht vom Pod, sondern vom kubelet auf dem Node — und Cilium maskiert
Pod-Egress ohnehin auf die Node-Adresse.

`no_root_squash`, weil Container regelmäßig als `root` schreiben und ihre
Dateien sonst `nobody` gehören. Es heißt zugleich, dass `root` im Cluster auch
auf dem Share `root` ist; die Regel ist deshalb auf die eine Adresse begrenzt.

**Die Adressbegrenzung deckt aber nur die halbe Bedrohung.** Sie hält andere
Geräte im Heimnetz fern. Gegen einen übernommenen Pod hilft sie nicht — der
erreicht den Share ja bestimmungsgemäß. Ohne weitere Maßnahme wäre die Kette:

1. Ein Pod, der als `root` läuft, legt eine setuid-root-Binary auf dem Share ab
   (erlaubt durch `no_root_squash`).
2. Irgendein Pod führt sie vom Mount aus aus.
3. Root auf dem Node — und auf einem Ein-Node-Cluster ist das der ganze Cluster.

Schritt 2 ist deshalb im Mount geschlossen: Sowohl die StorageClass als auch
das statische PV tragen `nosuid`, `nodev` und `noexec` (Begründung je Option in
[nfs-storage.yaml](nfs-storage.yaml)). `sec=sys` steht dort ausdrücklich, damit
beim Lesen sichtbar ist, dass diese Strecke keine Authentisierung hat.

Der saubere Weg wäre `root_squash`. Er scheitert heute daran, dass die Dienste,
die vom Host herüberziehen, als `root` schreiben. Sobald sie über `runAsUser`
und `fsGroup` feste IDs führen, ist das der nächste Schritt — dann fällt auch
`no_root_squash` weg.

Dass der Weg überhaupt offen ist, hängt an Unraids *Host access to custom
networks* — siehe [vm/talos/README.md](../../../../vm/talos/README.md#macvtap-wer-wen-erreicht).
Nachprüfen lässt sich das ohne Testdienst aus dem `csi-nfs-node`-Pod heraus; er
läuft mit `hostNetwork`, steht also genau dort, wo auch das kubelet mountet:

```bash
kubectl -n csi-driver-nfs exec ds/csi-nfs-node -c nfs -- \
  timeout 10 showmount -e 192.168.178.3
```

Kommt eine Export-Liste zurück, ist der Weg offen und jede weitere Fehlersuche
gehört auf die Share-Namen und die Export-Regeln, nicht auf das Netz.

### Voraussetzung in der VM

Der lokale Speicher braucht die zweite Disk. Sie entsteht mit `tofu apply` in
[vm/talos](../../../../vm/talos), wird aber erst beim **nächsten Start der VM**
sichtbar — libvirt hängt sie an eine laufende Maschine nicht von selbst an:

```bash
talosctl -n <node-ip> get disks                  # erwartet: vda und vdb
talosctl -n <node-ip> get volumestatus           # erwartet: u-local-path ready
talosctl -n <node-ip> get volumemountstatus      # erwartet: /var/mnt/local-path
```

Das Partitionslabel `u-local-path` vergibt Talos aus dem Volume-Namen; unter
diesem Namen taucht es in `volumestatus` auf, nicht als `local-path`.

Fehlt `vdb`, bleibt der Provisioner ohne Verzeichnis, und PVCs stehen auf
`Pending` — das Event am Pod nennt dann den Pfad.

**`vdb` da und trotzdem `Pending`?** Dann liegt es am Volume, nicht an der
Disk, und der Fehler steht nur in der Talos-Ressource — nicht im Apply, nicht
im Provisioner-Log:

```bash
talosctl -n <node-ip> get volumestatus u-local-path -o yaml
```

Steht dort `phase: failed`, sagt `errorMessage`, warum. Nach außen sieht es
harmlos aus: `/var/mnt` bleibt read-only, und der Helper-Pod des Provisioners
scheitert an `mkdir /var/mnt/local-path/: read-only file system`. Genau so ist
`!system_disk` im Disk-Selektor aufgefallen — der Ausdruck übersetzt sich, die
Variable wird bei User-Volumes aber nicht gebunden. Begründung und Ersatz in
[vm/talos/patches/uservolume.yaml.tftpl](../../../../vm/talos/patches/uservolume.yaml.tftpl).

### Gegenproben

```bash
kubectl get sc                    # local-path (default), nfs-unraid
kubectl -n local-path-storage get pods
kubectl -n csi-driver-nfs get pods
kubectl get pv

# Der Beweisfall - schreibt über die Default-Klasse und liest zurück:
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: nfs-smoketest }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 1Gi } }
EOF
kubectl get pvc nfs-smoketest     # erwartet: Bound
ssh root@192.168.178.3 ls /mnt/user/k8s
kubectl delete pvc nfs-smoketest  # Verzeichnis bleibt liegen (onDelete: retain)
```

Hängt ein Pod beim Start in `ContainerCreating`, steht der Grund im Event, nicht
im Log:

```bash
kubectl describe pod <name> | tail -20
kubectl -n csi-driver-nfs logs ds/csi-nfs-node -c nfs | tail
```

## `cloudnative-pg.yaml`

Der Operator, dem die Postgres-Instanzen der migrierten Dienste gehören. Was er
löst und warum er kommt, steht in [../../../AUSBAUSTUFEN.md](../../../AUSBAUSTUFEN.md),
Stufe 1 — kurz: Man deklariert einen `Cluster`, kein Passwort.

Er läuft `clusterWide` in `cnpg-system`; die Instanzen selbst liegen **nicht**
dort, sondern im Namespace des jeweiligen Dienstes. Der Operator spricht sie
über zwei Ports an: den Instance Manager auf `8000` für den Zustand und
Postgres auf `5432` für Rollen und Datenbanken. Beides muss in `cnpg-egress`
je Namespace freigegeben werden — sonst bleibt der `Cluster` auf *Setting up
primary* stehen.

### Warum hier keine `ScheduledBackup` steht

CNPG kennt drei Backup-Methoden, und keine schreibt in ein PVC:
`barmanObjectStore` und `plugin` wollen einen Objektspeicher, `volumeSnapshot`
einen snapshot-fähigen CSI-Treiber plus snapshot-controller. `local-path` kann
das nicht — und dort liegt PGDATA, aus den Gründen weiter oben unter
[local-path.yaml, nfs-storage.yaml](#local-pathyaml-nfs-storageyaml).

Deshalb: **`pg_dump` per CronJob, alle 12 h, auf ein PVC der Klasse
`nfs-unraid`** — also nach `/mnt/user/k8s`, wo Kopia es abholt
([../../../CHECKLISTE.md](../../../CHECKLISTE.md), Abschnitt A). Der Preis ist
entschieden und ausdrücklich: kein PITR.

### Vorlage je Dienst

Der CronJob braucht das Secret `<cluster>-app` und ist damit
namespace-gebunden — er gehört in die Datei des Dienstes, nicht hierher. Am
Beispiel `nextcloud`:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: nextcloud-db
  namespace: nextcloud
spec:
  instances: 1                    # ein Node, keine Hochverfügbarkeit
  storage:
    size: 20Gi                    # ohne storageClass -> local-path (Default)
  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits:   { memory: 1Gi }
---
# Das Ziel der Dumps: ein ganz gewoehnliches PVC der Klasse `nfs-unraid`,
# also der Share /mnt/user/k8s - der einzige Weg, auf dem etwas aus dem
# Cluster auf dem Array landet, und nur dort sieht Kopia es.
#
# Der Name des PVC landet im Pfad: die StorageClass setzt `subDir` auf
# <namespace>/<pvc-name>, das ergibt /mnt/user/k8s/nextcloud/dumps.
# Deshalb schlicht "dumps" - der Dienst steckt schon im Namespace.
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: dumps
  namespace: nextcloud
spec:
  accessModes: [ReadWriteMany]
  storageClassName: nfs-unraid
  resources:
    requests:
      storage: 20Gi            # NFS erzwingt kein Kontingent, nur Buchhaltung
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: nextcloud-db-dump
  namespace: nextcloud
spec:
  schedule: "0 */12 * * *"        # 00:00 und 12:00
  timeZone: Europe/Berlin         # sonst UTC, und die Zeitstempel lügen
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        spec:
          restartPolicy: OnFailure
          securityContext:
            runAsNonRoot: true
            runAsUser: 26         # postgres im CNPG-Image
            runAsGroup: 26
            fsGroup: 26
            seccompProfile: { type: RuntimeDefault }
          containers:
            - name: dump
              # Dasselbe Image wie die Instanz. pg_dump muss zur Server-
              # Version passen; ein fremdes Image ist der Fehler, der erst
              # beim Versionssprung auffällt.
              image: ghcr.io/cloudnative-pg/postgresql:17.6
              securityContext:
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                capabilities: { drop: [ALL] }
              env:
                - { name: PGHOST,     valueFrom: { secretKeyRef: { name: nextcloud-db-app, key: host } } }
                - { name: PGPORT,     valueFrom: { secretKeyRef: { name: nextcloud-db-app, key: port } } }
                - { name: PGUSER,     valueFrom: { secretKeyRef: { name: nextcloud-db-app, key: username } } }
                - { name: PGPASSWORD, valueFrom: { secretKeyRef: { name: nextcloud-db-app, key: password } } }
                - { name: PGDATABASE, valueFrom: { secretKeyRef: { name: nextcloud-db-app, key: dbname } } }
              command: [/bin/bash, -c]
              args:
                - |
                  set -euo pipefail
                  out="/dumps/nextcloud-$(date +%Y-%m-%dT%H%M).dump"

                  # --compress=0 mit Absicht: Kopia dedupliziert und
                  # komprimiert selbst. Ein komprimierter Dump unterscheidet
                  # sich ab der ersten geänderten Zeile auf ganzer Länge vom
                  # vorigen - jeder Snapshot legt dann eine vollständige neue
                  # Kopie ab. Unkomprimiert teilen sich zwei Dumps das meiste.
                  # Der Preis ist Platz auf dem Array, und der ist billig.
                  pg_dump --format=custom --compress=0 \
                          --no-owner --no-privileges --file="${out}.part"

                  # Erst fertig schreiben, dann umbenennen. Ein `mv` innerhalb
                  # desselben Dateisystems ist atomar - Kopia sieht damit
                  # entweder den alten vollständigen Dump oder den neuen, nie
                  # einen halben. Ohne das ist ein Snapshot, der zufällig
                  # während des Dumps läuft, unbrauchbar, und man merkt es
                  # beim Restore.
                  mv "${out}.part" "${out}"

                  # Lokale Vorhaltung. Die Tiefe hat Kopia, hier reicht der
                  # kurze Rückweg ohne Restore.
                  ls -1t /dumps/nextcloud-*.dump | tail -n +15 | xargs -r rm --
              volumeMounts:
                - { name: dumps, mountPath: /dumps }
                - { name: tmp,   mountPath: /tmp }
          volumes:
            - name: dumps
              persistentVolumeClaim:
                claimName: dumps
            - name: tmp
              emptyDir: {}
```

Dazu je Dienst:

- **`cnpg-egress` erweitern** — der Namespace mit `cnpg.io/podRole: instance`
  auf `5432` und `8000`, sonst kommt die Datenbank nicht hoch. Der Block steht
  auskommentiert in [cloudnative-pg.yaml](cloudnative-pg.yaml).
- **Egress im Dienst-Namespace** — CoreDNS und die eigene Instanz auf `5432`.
  Der CronJob-Pod fällt unter dieselbe Regel wie die Anwendung.
- **Reloader** — der Namespace gehört in die Liste in
  [reloader.yaml](reloader.yaml), sobald ein Secret aus `homelab-secrets` dort
  in `env` hängt. Für das `-app`-Secret ist er *nicht* nötig: Rotiert der
  Operator es über `spec.managed.roles`, ändert er beide Seiten selbst — genau
  die Lücke, die Reloader offenlässt.

### Wo der Dump landet

```
/mnt/user/k8s/nextcloud/dumps/nextcloud-2026-09-10T0300.dump
```

Ein Pfad, den man vorlesen kann. Er entsteht aus einer Zeile an der
StorageClass `nfs-unraid` ([nfs-storage.yaml](nfs-storage.yaml)):

```yaml
subDir: ${pvc.metadata.namespace}/${pvc.metadata.name}
```

### Der Weg zurück

Kein Restore *in* eine laufende Instanz — der Weg ist immer: `Cluster`-CR
anwenden, der Operator legt eine leere Instanz an, Dump einspielen.

```bash
kubectl -n nextcloud exec -it nextcloud-db-1 -- \
  pg_restore --clean --if-exists --no-owner --no-privileges \
             -d nextcloud /dumps/nextcloud-<zeitstempel>.dump
```

Das Passwort entsteht dabei neu und fehlt niemandem, solange die Anwendung es
per `secretKeyRef` liest statt aus einer env-Datei.

### Migration aus dem Docker-Container

`bootstrap.initdb.import` mit `type: microservice` fährt pg_dump/pg_restore
gegen die alte Instanz, inklusive Versionssprung. Zwei Dinge fallen dabei auf,
die es sonst nicht gibt:

- Das alte `POSTGRES_PASSWORD` braucht man **ein letztes Mal** als temporäres
  Secret im Namespace. Danach nie wieder — es gehört nach der Migration aus
  `homelab-secrets` heraus.
- Der Import spricht den Unraid-Host an, und ins Heimnetz darf sonst keiner
  (siehe [Egress](#egress-wer-aus-dem-cluster-heraus-darf)). Die Regel dafür
  ist eine **befristete** Ausnahme auf `192.168.178.3:5432`, die mit dem
  temporären Secret zusammen wieder verschwindet. Sie im Repo stehen zu lassen
  wäre der stille Weg zurück in ein flaches Netz.

### Gegenproben

```bash
kubectl -n cnpg-system get deploy,pods
kubectl -n nextcloud get cluster,pods
kubectl -n nextcloud get cronjob nextcloud-db-dump

# Einen Lauf erzwingen, statt zwölf Stunden zu warten
kubectl -n nextcloud create job --from=cronjob/nextcloud-db-dump dump-test
kubectl -n nextcloud logs job/dump-test

# Und die Gegenprobe, auf die es ankommt - auf dem Host, nicht im Cluster
ssh root@192.168.178.3 ls -lh /mnt/user/k8s/nextcloud/dumps/
```

Bleibt der `Cluster` auf *Setting up primary*, ist die erste Stelle `cnpg-egress`:

```bash
kubectl -n kube-system exec ds/cilium -- \
  hubble observe --namespace cnpg-system --type drop --last 100
```

## `monitoring.yaml`

VictoriaMetrics-Stack mit Grafana: VM-Operator, `vmsingle` als Speicher,
`vmagent` als Sammler, `vmalert` und Alertmanager, dazu kube-state-metrics,
node-exporter und Grafana unter `grafana.k8s.nico-steinmueller.de`.

**Warum nicht `kube-prometheus-stack`:** das RAM. Gemessen am 2026-09-11, vor
jeder migrierten Anwendung, lag der Node bei 2717 von 3276 MiB — 83 %. Deshalb
steht `vm_memory_mib` jetzt auf 6144; dieser Stack kommt mit grob 800 MiB
Requests aus, der Prometheus-Stack läge beim Doppelten bis Dreifachen.

Der Operator konvertiert Prometheus-Operator-Objekte selbst
(`disable_prometheus_converter: false`). Die Schalter `serviceMonitor.enabled`
in [reloader.yaml](reloader.yaml) und `podMonitorEnabled` in
[cloudnative-pg.yaml](cloudnative-pg.yaml) bleiben damit gültig — sie müssen
nur auf `true` gedreht werden.

### Was auf Talos nicht scrapebar ist

`kubeEtcd`, `kubeControllerManager` und `kubeScheduler` stehen im Chart auf
`true` und wären hier dauerhaft rot: etcd lauscht mit Client-Zertifikaten und
ist von der Ingress-Firewall ohnehin zu, die beiden Static Pods bindet Talos
auf `127.0.0.1`. Sie sind deshalb **aus** und nicht ignoriert — ein Monitoring,
dessen Startzustand kaputte Targets sind, bringt niemandem bei, auf rote
Targets zu achten. `kubeProxy` bleibt aus, weil Cilium ihn ersetzt.

Das Kubelet wird über HTTPS, aber ungeprüft gescrapt
(`insecureSkipVerify: true`) — dieselbe Lücke wie beim metrics-server, mit
demselben Grund: kein kubelet-csr-approver.

### Der Sync-Job

Dashboards und Alarmregeln liefert der Chart nicht als Template, sondern über
einen Job, der sie beim Deployen aus dem Netz holt. Zwei Folgen:

- Es ist eine **bewegliche Quelle**, anders als alles andere in diesem
  Verzeichnis. Bewusst hingenommen, weil der Regelsatz der Grund für diesen
  Chart ist.
- Der Job ist ein Helm-Hook (`post-install,post-upgrade`), Helm wartet auf ihn.
  Ohne Egress ins Internet scheitert **die ganze HelmRelease**, nicht nur die
  Dashboards. Dafür gibt es `monitoring-syncjob-egress` — auf den Job
  eingegrenzt, `except` auf RFC 1918 wie bei der ACME-Regel.

### Voraussetzung

Das Secret `grafana-admin` mit `admin-user` und `admin-password` muss in
`homelab-secrets` liegen, sonst startet Grafana nicht.

```bash
kubectl -n monitoring get pods
kubectl -n monitoring get vmsingle,vmagent,vmalert,vmalertmanager
kubectl -n flux-system get helmrelease victoria-metrics-k8s-stack

# Targets, die nicht antworten - die erste Stelle ist monitoring-egress
kubectl -n kube-system exec ds/cilium -- \
  hubble observe --namespace monitoring --type drop --last 100
```
