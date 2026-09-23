# network

Was Verkehr in den Cluster hinein lässt — und die Adressen, unter denen er
ankommt.

| Komponente | Was |
|---|---|
| [`lb-ipam/`](lb-ipam) | die LAN-Adressen des Clusters und ihre Ankündigung |
| [`ingress-internal/`](ingress-internal) | Traefik für das Heimnetz, IngressClass `internal` |
| [`ingress-public/`](ingress-public) | Traefik für das Internet, IngressClass `public` |
| [`crowdsec/`](crowdsec) | LAPI und Agent hinter dem öffentlichen Controller |
| [`Sources.yaml`](Sources.yaml) | HelmRepositories `traefik` und `crowdsec` |

`dependsOn: cert-manager-issuers` ([`../sync/Network.yaml`](../sync/Network.yaml)),
weil der CrowdSec-Chart `Certificate`-Objekte gegen den ClusterIssuer
`homelab-ca` templatet.

## `lb-ipam/`

Welche Adressen es gibt (`CiliumLoadBalancerIPPool`, `.231`–`.232`) und wie das
Netz von ihnen erfährt (`CiliumL2AnnouncementPolicy` auf `enp1s0`).

Zwei Teile, die man auseinanderhalten muss — die Verwechslung ist der häufigste
Fehler an dieser Stelle:

| | was es tut | wo es eingeschaltet wird |
|---|---|---|
| **LB-IPAM** | *vergibt* eine Adresse an einen Service | nirgends — es genügt, dass ein IPPool existiert |
| **L2-Announcement** | *kündigt* sie per Gratuitous ARP an | `l2announcements.enabled` in [cilium.yaml.tftpl](../../../vm/talos/values/cilium.yaml.tftpl) |

Fehlt der zweite Teil, sieht der Service **gesund aus** — `EXTERNAL-IP` steht da
— und ist trotzdem für niemanden erreichbar. Die aussagekräftige Gegenprobe ist
deshalb nicht der Service, sondern die Lease:

```bash
kubectl -n kube-system get lease | grep l2announce
kubectl get ciliumloadbalancerippools,ciliuml2announcementpolicies
```

Der Wert in den Cilium-Werten setzt zweierlei: das Agent-Flag
`enable-l2-announcements` **und** die RBAC-Regeln auf
`coordination.k8s.io/leases`. Wer die Abkürzung über `kubectl patch cm
cilium-config` nimmt, bekommt nur das Flag — und damit einen Agent, der
ankündigen will und nicht darf (`leases.coordination.k8s.io … is forbidden`).

Die Zuordnung Service → Adresse steht **nicht** hier, sondern als Annotation
`lbipam.cilium.io/ips` am jeweiligen Service. Ohne sie wäre sie die Reihenfolge
der Vergabe — und ein Neustart könnte die beiden Ingress-Adressen tauschen,
mitten in einer bestehenden Portfreigabe.

Die beiden CRs tragen verschiedene apiVersions: Beim IPPool ist `cilium.io/v2`
die Storage-Version, die L2-Policy kennt in Cilium 1.20.1 **kein** `v2`. Beim
Cilium-Update mitprüfen.

## `ingress-internal/`

Erreichbar ausschließlich aus dem Heimnetz. Namespace, IngressClass `internal`,
NetworkPolicies und die Traefik-Release.

### hostPort statt hostNetwork

Der frühere Plattform-Stack fuhr beide Controller mit `hostNetwork` und band sie
über `hostIP` an je eine Node-Adresse. Das kostete den Sysctl
`net.ipv4.ip_unprivileged_port_start=0` auf dem Node, weil Traefik als UID 65532
sonst 80 und 443 nicht binden darf.

Beides ist weg: Der Node hat ein Bein, Traefik bindet 8000/8443 im eigenen
Pod-Netz, wo es kein Privileg braucht, und Cilium bildet Node:80/443 darauf ab.
Das kann es, weil kube-proxy durch Cilium ersetzt ist.

### Was den Zugang begrenzt

| | wodurch |
|---|---|
| Von außen nur aus dem LAN | NetworkPolicy `allow-from-lan` (`ipBlock` auf das Heimnetz) |
| An die Anwendungen nur über den Controller | `default-deny-ingress` je Namespace plus eine Regel auf `traefik-internal` |
| Secrets nur in den gelisteten Namespaces | eigene RBAC statt der des Charts |

Der letzte Punkt ist die Bremse, die man beim nächsten Dienst spürt: Ein neuer
Namespace muss an **drei** Stellen stehen — `providers.kubernetesIngress.namespaces`,
`providers.kubernetesCRD.namespaces` und als RoleBinding. Fehlt die Bindung,
sieht Traefik den Namespace nicht; fehlt er in den Listen, schaut Traefik nicht
hin.

### RBAC von Hand, und warum

`rbac.namespaced: true` wäre der naheliegende Weg. Der Chart koppelt daran aber
ein zweites Verhalten, und das macht den Ingress unbrauchbar:

```
rbac.namespaced: true  ->  --providers.kubernetesingress.disableClusterScopeResources=true
```

Mit diesem Flag holt Traefik die Liste der IngressClasses gar nicht erst. Und
weil `shouldProcessIngress` bei gesetztem `spec.ingressClassName`
**ausschließlich** gegen diese Liste prüft, fällt jeder Ingress durch — ohne
Logzeile, mit 404 am Controller.

Deshalb `rbac.enabled: false`: Dann erzeugt der Chart keine RBAC und setzt das
Flag auch nicht, denn es hängt allein an `rbac.namespaced`. Die Rechte stehen
stattdessen als eigene Objekte in `RBAC.yaml`:

| | Rechte |
|---|---|
| ClusterRole `traefik-internal-cluster` | `nodes`, `namespaces`, `ingressclasses` — keine Geheimnisse |
| ClusterRole `traefik-internal-namespaced` | der Rest, **inkl. Secrets** — gebunden nur per RoleBinding je Namespace |

Die zweite ClusterRole wird nirgends clusterweit gebunden. Eine RoleBinding darf
eine ClusterRole referenzieren, und die Rechte gelten dann nur in ihrem
Namespace — das spart dreimal dieselbe Regelliste, ohne die Zusage aufzugeben:
Wer den Ingress übernimmt, bekommt nicht die Secrets des ganzen Clusters dazu.

Der Preis, ehrlich benannt: Diese Regeln spiegeln, was sonst der Chart pflegt
(`templates/rbac/role.yaml`, hier aus 41.3.0). Ändert ein Traefik-Update die
nötigen Rechte, muss das hier nachziehen — sichtbar, weil Traefik dann
RBAC-Fehler protokolliert.

Die RoleBindings heißen bewusst `traefik-internal-namespaced` und nicht wie der
Chart `traefik-internal`: `roleRef` ist unveränderlich, und wo schon eine Bindung
dieses Namens auf eine *Role* zeigt, scheitert jedes Apply mit
`cannot change roleRef`.

### Das Dashboard

`https://traefik.k8s.nico-steinmueller.de` — **mit Passwort**. Traefiks Dashboard
kennt selbst keine Authentifizierung, und „nur im LAN erreichbar" ist keine. Wer
es öffnet, sieht jeden Router und jede Middleware — also eine Liste dessen, was
es in diesem Cluster zu erreichen gibt.

| Objekt | wo |
|---|---|
| IngressRoute `traefik-internal-dashboard` | vom Chart, `ingressRoute.dashboard` |
| Middleware `traefik-dashboard-auth` | eigenes Manifest in derselben Datei |
| Middleware `traefik-dashboard-root` | leitet `/` auf `/dashboard/` |
| Secret `traefik-dashboard-auth` | SOPS-verschlüsselt in `homelab-secrets` |

Die Match-Regel ist bewusst nur `Host(...)` statt der Chart-Voreinstellung
``PathPrefix(`/dashboard`) || PathPrefix(`/api`)``: Der Hostname gehört allein
diesem Dashboard, und mit der Voreinstellung wäre ausgerechnet die eingetippte
Adresse ohne Pfad ein 404.

Einen zweiten, ungeschützten Weg gibt es **nicht**. Der Entrypoint `traefik`
(8080) trägt nur `/ping`; auf 8080 läge die API erst mit `--api.insecure=true`,
und das Flag setzt der Chart nicht.

```bash
python3 -c 'import bcrypt,getpass; print("nico:"+bcrypt.hashpw(getpass.getpass().encode(), bcrypt.gensalt(rounds=12)).decode())'
sops cluster/traefik-dashboard-auth.sops.yaml   # in homelab-secrets
```

Traefik liest das Secret über seinen Informer — der Wechsel gilt sofort, ohne
Pod-Neustart.

### Das Zertifikat

Ein **Wildcard von Let's Encrypt** für `*.k8s.nico-steinmueller.de`, per DNS-01
über IONOS — von Traefik selbst geholt, nicht von cert-manager. Port 80 leitet
dauerhaft auf 443 um. Drei Entscheidungen stecken darin:

- **Traefik statt cert-manager**, weil cert-manager keinen IONOS-Solver hat. Für
  IONOS bräuchte es den Webhook eines Drittanbieters — ein weiterer Controller,
  der den Zonen-Token bekäme. Traefik bringt lego mit, und lego kennt IONOS.
- **Wildcard statt Zertifikat je Name**, wegen Certificate Transparency: Einzeln
  ausgestellt stünde jeder Dienstname in öffentlichen Logs — eine Landkarte des
  Heimnetzes. Beim Wildcard steht dort nur, dass es eine `k8s.`-Zone gibt.
- **Let's Encrypt statt eigener CA**, weil jedes Gerät ihr ab Werk vertraut.

Das Zertifikat hängt am **Entrypoint**, nicht an den Ingress-Objekten. Ein neuer
Dienst braucht damit keinen `tls:`-Block und kein eigenes Secret.

> **Der Resolver steht auf dem Produktivverzeichnis.** Wer an der
> DNS-01-Challenge etwas ändert, probiert das wieder in Staging aus — die Rate
> Limits sind hart: fünf fehlgeschlagene Validierungen je Konto und Hostname pro
> Stunde, und ein falscher API-Key verbraucht die in Minuten.
>
> **Beim Umstellen muss `acme.json` weg**, in beide Richtungen. Es trägt das
> Zertifikat *und* die Registrierungs-URI des ACME-Kontos, und Traefik verwirft
> es nicht von allein: Das alte Zertifikat ist gültig, wird also weiter
> ausgeliefert (es sieht aus, als sei nichts passiert), und das Staging-Konto
> quittiert das Produktivverzeichnis mit `account does not exist`.
>
> ```bash
> kubectl -n traefik-internal exec deploy/traefik-internal -- rm -f /data/acme.json
> kubectl -n traefik-internal rollout restart deploy/traefik-internal
> ```

Der API-Key liegt SOPS-verschlüsselt als `traefik-ionos` in `homelab-secrets`.
lego liest ihn ausschließlich aus der Umgebung, deshalb `env` und keine Datei.

### Voraussetzung im Heimnetz

Nicht im Repo abgebildet: Die Hostnamen müssen **nur intern** auf die
LAN-Adresse zeigen (AdGuard oder Fritzbox), nicht über DynDNS.

```
dashboard.k8s.nico-steinmueller.de  ->  192.168.178.230
traefik.k8s.nico-steinmueller.de    ->  192.168.178.230
whoami.k8s.nico-steinmueller.de     ->  192.168.178.230
```

Die eigene Zone `k8s.` ist dabei der Punkt: Die Dienste auf dem Unraid-Host
liegen unter `*.local.nico-steinmueller.de`. Am Namen ist damit ablesbar, wo ein
Dienst läuft — und ein Umzug in den Cluster ist ein sichtbarer Namenswechsel
statt einer stillen Umleitung.

## `ingress-public/`

Der Controller für das Internet — ein eigener und nicht ein zweiter Entrypoint
des internen: eigener Namespace, eigene Adresse, eigene RBAC, eigener
Zertifikatsspeicher.

Die Vertrauensgrenze ist hier das offene Internet. Entsprechend sitzt vor jedem
Router eine Kette: CrowdSec-Bouncer, HSTS, Ratelimit. Beim internen Controller
gibt es das nicht, und das ist kein Versehen — wer im LAN steht, hat ohnehin
mehr Wege als diesen.

Gefälschte Herkunftsheader stehen nicht in der Kette, obwohl sie dorthin
gehörten: Dagegen wirkt `forwardedHeaders.trustedIPs: []`, und zwar vollständig
— Traefik übernimmt die `X-Forwarded-*`-Kopfzeilen nicht, es überschreibt sie.

> **Stand: whoami ist der einzige Dienst hier drin.** Immich und Nextcloud laufen
> weiter als Container auf dem Unraid-Host. Vier Stellen sind im Ordner als
> BAUSTELLE markiert und beim Migrieren nachzuziehen: die beiden
> `namespaces`-Listen, eine RoleBinding je Dienst-Namespace und ein
> `toEndpoints`-Block in der CiliumNetworkPolicy.

Was noch fehlt und bewusst nicht dort steht: AppSec (kommt mit dem ersten
Dienst, an dem eine WAF-Regel etwas zu prüfen hat) und die Portfreigabe in der
Fritzbox — die kommt zuletzt.

## `crowdsec/`

Der Agent liest die Zugriffslogs von `ingress-public`, wertet sie gegen die
Szenarien des Hub aus und meldet Treffer an die LAPI. Der Bouncer sitzt als
Plugin im Traefik von `ingress-public` und fragt dort nach, bevor er eine
Anfrage durchlässt. Drei Teile, drei Orte — das ist der Unterschied zum
Docker-Stand auf dem Host, wo alles in einem compose-Netz lag.

Der Agent weist sich per Client-Zertifikat aus (`tls.enabled`) und nicht per
registriertem Passwort. Das ist der Grund, warum cert-manager im Cluster ist;
die Vorgeschichte steht in [../platform/README.md](../platform/README.md).

Bewusst nicht dabei: AppSec, Console-Registrierung und das Metabase-Dashboard —
`cscli decisions list` beantwortet dieselbe Frage.

## Gegenproben

```bash
kubectl -n traefik-internal get pods
kubectl get ingressclass
kubectl get ingress -A                 # ADDRESS bleibt leer, siehe unten

curl -k https://whoami.k8s.nico-steinmueller.de
curl -k -o /dev/null -w '%{http_code}\n' https://traefik.k8s.nico-steinmueller.de/dashboard/
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
