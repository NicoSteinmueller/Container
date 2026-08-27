# Öffentlicher Zugang ohne Edge-VM

Der Weg von heute — ein Node, ein interner Ingress, nichts aus dem Internet
erreichbar — zu Immich und Nextcloud im Internet, **ohne** die vorgelagerte
Edge-VM aus [../vm/edge](../vm/edge).

Dieses Dokument ersetzt die Schritte 4, 5 und 8 aus
[INBETRIEBNAHME.md](INBETRIEBNAHME.md). Die Schritte 0 bis 3 dort gelten
unverändert; Schritt 6 und 7 ebenso. Was hier steht, ist noch nicht gebaut.

## Die Entscheidung

Das [Sicherheitskonzept](homelab-sicherheitskonzept.html) begründet unter **E2**
eine vorgelagerte VM statt der direkten Freigabe auf den Ingress: Der
Ingress-Pod hält ein ServiceAccount-Token und liest TLS-Secrets, deshalb sollen
Sperren außerhalb der potenziell kompromittierten Zone durchgesetzt werden.
Verworfen wurde damals „RBAC härten plus Bouncer auf dem Unraid-Host".

Diese Entscheidung wird hier umgedreht. Die Gründe, in der Reihenfolge ihres
Gewichts:

1. **Der Schutz von E2 deckt den unwahrscheinlichen Zweig ab.** Traefik ist ein
   Go-Binary mit kleiner Angriffsfläche. Die realistische Kompromittierung kommt
   über Nextcloud oder Immich — und die laufen in beiden Varianten im Cluster.
2. **Die Verarbeitungskette zieht mit um.** Von den sechs Stufen in
   [../vm/edge/README.md](../vm/edge/README.md) sind vier reine
   Traefik-Konfiguration und eine CrowdSec-Konfiguration. Der heutige
   Docker-Stand beweist das: [../traefik/compose.yml](../traefik/compose.yml)
   fährt CRS, Virtual Patching und die Nextcloud-/Immich-Collections bereits im
   selben Netz wie den Proxy.
3. **1,5 GB RAM** auf einem Host, dem der Plattform-Stack bei 3 GB messbar nicht
   gepasst hat.
4. **Ein Betriebsmodell statt zwei.** Die Edge ist Terraform plus cloud-init,
   außerhalb von GitOps — das nennt E2 selbst als Preis.

Mit der Edge werden vier weitere Entscheidungen gegenstandslos: **E3**
(TLS-Terminierung auf der Edge), **E4** (zwei getrennte ACME-Clients), **E5**
(mTLS Edge → Cluster, samt interner CA) und **E9** (kein Wildcard, damit der
Schlüssel nicht auf der exponierten VM liegt — es gibt keine exponierte VM
mehr). **E7** bleibt sinngemäß gültig und wird in Schritt 6 umgesetzt.

## Was der Verzicht kostet

Vier Dinge gehen verloren. Drei lassen sich kompensieren, eines nicht.

| Verlust | Kompensation |
|---|---|
| **Hostnamen-Whitelist außerhalb des Clusters.** Die Edge kennt nur die Namen aus `public_services` — ein Manifest mit falschem `ingressClassName: public` käme trotzdem nicht ins Internet. | Die Namespace-Liste von `ingress-public` (Schritt 4) übernimmt diese Rolle: Ein Controller mit `rbac.namespaced` bedient **nur** die dort aufgezählten Namespaces. Die Liste steht in Git, ist explizit und wirkt unabhängig von der Ingress-Klasse. Dazu Kyverno (Schritt 5) als zweite Sperre. |
| **Isolation bei Ingress-Kompromittierung (E2).** | Eigener Namespace, `rbac.namespaced` mit minimaler ClusterRole, Default-Deny-NetworkPolicies, kein Zugriff auf das interne Wildcard-Zertifikat. Reduziert die Beute, hebt den Verlust aber nicht auf. |
| **L3-Blocking vor dem TLS-Handshake** durch den nftables-Firewall-Bouncer. | Nur der Traefik-Plugin-Bouncer auf L7. Gesperrte Adressen kosten weiterhin Handshake und Request. Für die Korrektheit der Sperre egal, für Brute-Force-Last relevant. **Nicht kompensierbar.** |
| **Die Portfreigabe zielt auf eine Maschine im vertrauten Netz** statt in ein isoliertes Segment. | Talos-Ingress-Firewall (Schritt 1) und eine eigene Adresse für den öffentlichen Ingress (Schritt 2). |

> **Eine zweite IP isoliert die Talos-API nicht.** `apid` bindet auf
> `0.0.0.0:50000/50001` und antwortet auf **jeder** Node-Adresse, auch auf der,
> die die Fritzbox als Ziel bekommt. Dagegen hilft ausschließlich Schritt 1.
> Deshalb steht er an erster Stelle und nicht irgendwo.

## Zielbild

Ein Node, zwei LoadBalancer-Adressen aus dem LAN, vergeben von Cilium per
LB-IPAM und im Netz angekündigt per L2-Announcement. Kein `hostPort`, kein
`hostNetwork`, kein Sysctl.

| Adresse | Wer lauscht | Erreichbar von |
|---|---|---|
| `192.168.178.230` | Node selbst: Talos-API, Kubelet, kube-apiserver | nur `admin_sources`, siehe Schritt 1 |
| `192.168.178.231` | `ingress-internal` — Headlamp, whoami, Paperless | nur LAN |
| `192.168.178.232` | `ingress-public` — Immich, Nextcloud | Internet (Fritzbox-Freigabe) **und** LAN über Split-DNS |

Beide LoadBalancer-Adressen müssen außerhalb des Fritzbox-DHCP-Bereichs liegen
und dürfen nicht mit `lan_ip` aus [../vm/talos](../vm/talos) kollidieren.

Warum LoadBalancer und nicht `hostIP` auf zwei Adressen: Der Kommentarblock in
[flux/clusters/talos-cp1/ingress-internal.yaml](flux/clusters/talos-cp1/ingress-internal.yaml)
beschreibt den `hostIP`-Weg und seine Folgekosten — das Chart schreibt `hostIP`
auch in die Entrypoint-Adresse, Traefik scheitert dann im Pod-Netz am Binden,
Ausweg ist `hostNetwork` plus `net.ipv4.ip_unprivileged_port_start=0`. Dazu
kommt eine Folge, die dort nicht steht: **Mit `hostNetwork` liegt der Pod im
Host-Namespace und trägt die Cilium-Identität `host`.** Die NetworkPolicies
`default-deny-ingress` und `allow-from-lan` in derselben Datei greifen dann
nicht mehr wie heute — Cilium erzwingt Policies gegen Host-Netzwerk-Pods nur
mit aktivierter Host-Firewall und `CiliumClusterwideNetworkPolicy`. Der
LoadBalancer-Weg lässt die Pods im Pod-Netz und damit alle Policies so gültig,
wie sie heute begründet sind.

---

## 1. Talos-Ingress-Firewall

**Muss fertig sein, bevor die Fritzbox irgendetwas weiterleitet.** Heute ist die
Talos-API LAN-weit erreichbar, geschützt nur durch Client-Zertifikate:
`talosctl get nftableschains` kommt leer zurück, und
[../vm/talos/variables.tf](../vm/talos/variables.tf) kennt keine `admin_sources`.

Neue Variable in `vm/talos`, dazu ein Patch-Dokument. Talos nimmt dafür
eigenständige Machine-Config-Dokumente:

```yaml
# vm/talos/patches/firewall.yaml.tftpl
apiVersion: v1alpha1
kind: NetworkDefaultActionConfig
ingress: block
---
apiVersion: v1alpha1
kind: NetworkRuleConfig
name: talos-api
portSelector:
  ports: [50000, 50001]
  protocol: tcp
ingress:
%{ for src in admin_sources ~}
  - subnet: ${src}
%{ endfor ~}
---
apiVersion: v1alpha1
kind: NetworkRuleConfig
name: kube-apiserver
portSelector:
  ports: [6443]
  protocol: tcp
ingress:
%{ for src in admin_sources ~}
  - subnet: ${src}
%{ endfor ~}
  - subnet: ${pod_subnet}
---
apiVersion: v1alpha1
kind: NetworkRuleConfig
name: kubelet
portSelector:
  ports: [10250]
  protocol: tcp
ingress:
  - subnet: ${pod_subnet}
%{ for src in admin_sources ~}
  - subnet: ${src}
%{ endfor ~}
```

`pod_subnet` ist `10.244.0.0/16` — der metrics-server spricht das Kubelet aus
dem Pod-Netz an, ohne diese Zeile fällt `kubectl top` aus.

**Zwei Dinge vorher wissen:**

- **Ein falscher Regelsatz sperrt dich aus dem Node aus.** Der Rückweg ist die
  serielle Konsole: `virsh -c qemu+ssh://root@192.168.178.3/system console
  homelab-cp1`. Vor dem Apply `admin_sources` gegen die eigene Adresse prüfen.
- **Ob die Regeln auch den LoadBalancer-Verkehr sehen, ist offen.** Cilium
  verarbeitet LB-Verkehr in eBPF und kann Netfilter dabei umgehen; die Regeln
  für `apid` und Kubelet greifen dagegen sicher, weil das gewöhnliche
  Host-Prozesse sind. Das ist kein Problem — wir *wollen* den LB-Verkehr
  durchlassen —, aber es heißt: **verlass dich für die Absicherung der
  Ingress-Ports nicht auf diese Firewall**, dafür sind die NetworkPolicies
  zuständig. Nachmessen nach dem Apply:

```bash
talosctl -n 192.168.178.230 get nftableschains        # darf nicht mehr leer sein
nmap -Pn -p 50000,6443,10250 192.168.178.230          # von einem Nicht-Admin-Host
```

## 2. Cilium: LB-IPAM und L2-Announcements

Die Voraussetzung ist erfüllt — `kubeProxyReplacement: true` steht bereits in
[../vm/talos/values/cilium.yaml.tftpl](../vm/talos/values/cilium.yaml.tftpl),
Cilium läuft als v1.20.1. Es fehlen drei Zeilen in denselben Werten:

```yaml
l2announcements:
  enabled: true

# Die L2-Announcements arbeiten mit Leases; die Cilium-Doku empfiehlt dafür
# ein höheres Client-Limit, sonst drosselt der Agent sich selbst.
k8sClientRateLimit:
  qps: 20
  burst: 40
```

Cilium liegt als Inline-Manifest in der Machine-Config, das ist also ein
`tools/tf apply` in `vm/talos` und kein Flux-Commit.

Dazu ein neues Flux-Manifest `flux/clusters/talos-cp1/lb-ipam.yaml`:

```yaml
apiVersion: cilium.io/v2alpha1
kind: CiliumLoadBalancerIPPool
metadata:
  name: lan
spec:
  blocks:
    - start: "192.168.178.231"
      stop: "192.168.178.232"
---
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata:
  name: lan
spec:
  # Der LAN-Anschluss des Nodes. Name gegenprüfen mit
  #   talosctl -n 192.168.178.230 get links
  interfaces:
    - enp1s0
  loadBalancerIPs: true
  externalIPs: false
```

**Vor allem anderen verifizieren — und zwar mit einem Wegwerf-Dienst, nicht mit
dem Ingress.** Der Node hängt per `macvtap` an `bond0`; die Announcements sind
Gratuitous ARP für zusätzliche Adressen unter derselben MAC. Das sollte
durchgehen, aber „sollte" ist hier das operative Wort:

```bash
kubectl -n whoami patch svc whoami --type merge \
  -p '{"spec":{"type":"LoadBalancer"}}'
kubectl -n whoami get svc whoami          # EXTERNAL-IP muss vergeben werden
curl http://192.168.178.231              # von einem anderen LAN-Rechner
ip -4 neigh show | grep 192.168.178.231  # MAC muss die des Nodes sein
```

Kommt hier nichts an, ist die ganze Umstellung blockiert — dann bleibt nur
Weg A (`hostIP` mit `hostNetwork`, samt der Policy-Folge oben) oder ein zweites
virtuelles Interface. Erst wenn das hier funktioniert, weiter.

Danach den Patch zurücknehmen: `kubectl -n whoami patch svc whoami --type merge
-p '{"spec":{"type":"ClusterIP"}}'`.

## 3. `ingress-internal` auf LoadBalancer umstellen

In [flux/clusters/talos-cp1/ingress-internal.yaml](flux/clusters/talos-cp1/ingress-internal.yaml):

```yaml
service:
  enabled: true
  type: LoadBalancer
  annotations:
    lbipam.cilium.io/ips: "192.168.178.231"
  spec:
    # Feldname gegen die Chart-Version prüfen; in 41.x geht der spec-Block durch.
    externalTrafficPolicy: Local

ports:
  web:
    port: 8000
    exposedPort: 80
    expose:
      default: true
    http:
      redirections:
        entryPoint: { to: websecure, scheme: https, permanent: true }
  websecure:
    port: 8443
    exposedPort: 443
    expose:
      default: true
    # tls-Block unverändert
```

Zu entfernen: beide `hostPort`-Zeilen und der `updateStrategy: Recreate` — der
Grund dafür (der Scheduler behandelt hostPorts wie NodePorts, der neue Pod
bleibt Pending) fällt mit dem hostPort weg.

**`externalTrafficPolicy: Local` ist keine Feinheit.** Ohne sie wird die
Client-Adresse per SNAT auf die Node-Adresse ersetzt. Dann trägt das Paket die
Cilium-Identität `host` statt `world` — und damit greift die NetworkPolicy
`allow-from-lan` nicht mehr, aus genau dem Grund, den der Kommentar in derselben
Datei beschreibt (Cilium wertet `ipBlock` nicht gegen `host` und `remote-node`
aus). Zusätzlich sähe CrowdSec später überall dieselbe Quell-IP.

Zwei Aufräumarbeiten, die jetzt möglich werden:

- Der ausführliche Kommentarblock zu `hostPort`/`hostNetwork`/Sysctl ist
  gegenstandslos und sollte durch die Begründung für LoadBalancer ersetzt
  werden — nicht gelöscht, ersetzt.
- Das PodSecurity-Label des Namespace steht auf `enforce: privileged`, **nur**
  weil hostPorts ab `baseline` als Verstoß zählen. Ohne hostPort kann es zurück;
  der Pod läuft ohnehin als 65532 mit `readOnlyRootFilesystem`, gedroppten
  Capabilities und `RuntimeDefault`-Seccomp. Auf `restricted` stellen und den
  Rollout beobachten.

Abnahme: `https://dashboard.k8s.nico-steinmueller.de` löst weiter auf und
antwortet — der DNS-Eintrag muss dabei von `.230` auf `.231` umgezogen werden.

## 4. `ingress-public` bauen

Neues Manifest `flux/clusters/talos-cp1/ingress-public.yaml`, gebaut wie
`ingress-internal`, mit fünf Unterschieden:

1. **Eigener Namespace** `traefik-public`, eigene ClusterRole
   `traefik-public-namespaced`, eigene RoleBindings. Kein gemeinsames Objekt mit
   dem internen Controller.
2. **Eigene Adresse:** `lbipam.cilium.io/ips: "192.168.178.232"`,
   `externalTrafficPolicy: Local`.
3. **Die Namespace-Liste ist die Sicherheitsgrenze.** `rbac.namespaced: true`
   mit `providers.kubernetesIngress.namespaces` und
   `providers.kubernetesCRD.namespaces` auf genau die öffentlichen Dienste —
   anfangs `immich` und `nextcloud`, sonst nichts. Ein `ingressClassName:
   public` in einem nicht aufgeführten Namespace bleibt wirkungslos. Diese Liste
   ersetzt die Hostnamen-Whitelist der Edge und ist der Grund, warum ein
   einzelner Fehler im Manifest eines internen Dienstes ihn nicht exponiert.
4. **Kein Zugriff auf das interne Wildcard.** Eigener `certResolver`, eigener
   PVC für den ACME-Speicher, Zertifikate je Name über DNS-01 für die
   öffentliche Zone. Das Wildcard `*.k8s.nico-steinmueller.de` bleibt im
   Namespace `traefik-internal` und wird dort nicht herausgereicht — E10
   sinngemäß.
5. **Die Verarbeitungskette der Edge**, als dynamische Konfiguration am
   Entrypoint `websecure`: `sniStrict: true` ohne `defaultCertificate` (fremde
   Namen enden im Handshake), `strip-client-forwarded` gegen gefälschte
   Herkunftsheader, `forwardedHeaders.trustedIPs: []` (vor diesem Controller
   steht kein Proxy), HSTS, und die drei Ratelimit-Stufen. Die Vorlagen dafür
   stehen in
   [../vm/edge/templates/traefik/dynamic/](../vm/edge/templates/traefik/dynamic/)
   und sind bis auf den `serversTransport` unverändert übernehmbar.

NetworkPolicies im neuen Namespace:

```
default-deny-ingress          wie im internen Namespace
allow-from-world              ingress auf 8000/8443 ohne ipBlock-Einschränkung
allow-to-served-namespaces    egress nur zu immich/nextcloud und kube-dns
allow-to-crowdsec-lapi        egress auf die LAPI, Port und Namespace benannt
```

Und je öffentlichem Dienst — wie beim internen Controller — eine
NetworkPolicy im Ziel-Namespace, die `traefik-public` hereinlässt.

## 5. Kyverno — jetzt tragend, nicht mehr ergänzend

Mit der Edge gab es zwei unabhängige Sperren gegen „privater Dienst versehentlich
öffentlich": ihre Hostnamen-Liste und die Policy. Die erste ist weg. **Kyverno
gehört deshalb vor den ersten öffentlichen Dienst, nicht danach.**

Regel: `ingressClassName: public` nur in Namespaces mit dem Label
`exposure: public`. Damit muss ein Versehen an zwei Stellen gleichzeitig
passieren — Label am Namespace **und** Eintrag in der Namespace-Liste aus
Schritt 4 —, und beide stehen in Git und sind im Review sichtbar.

Die Reloader-Annotation, die Kyverno früher ebenfalls setzte, wird nicht mehr
gebraucht; siehe [flux/README.md](flux/README.md), Abschnitt Rotation.

## 6. CrowdSec im Cluster

Alle Bausteine sind aus dem Docker-Stand übernehmbar; die Collection-Liste steht
fertig in [../traefik/compose.yml](../traefik/compose.yml).

- **LAPI in einem eigenen Namespace** `crowdsec`, **nicht** in `traefik-public`.
  Das ist E7 eine Ebene tiefer: Die exponierte Komponente darf Entscheidungen
  nicht löschen. Der Bouncer-Key ist lesend, die NetworkPolicy der LAPI lässt
  nur `traefik-public` auf den einen Port.
- **Agent** liest die Traefik-Logs von `ingress-public`, plus die Logs der
  Anwendungen dort, wo sie entstehen.
- **AppSec-Listener** mit `crowdsecurity/appsec-virtual-patching`,
  `appsec-crs` und der Nextcloud-Exclusion — zwei Listener wie auf der Edge:
  Virtual Patching plus CRS für die strengen Pfade, Virtual Patching allein für
  `/remote.php/*`.
- **Bouncer** als Traefik-Plugin-Middleware am öffentlichen Entrypoint.
  `clientTrustedIPs` auf das LAN, sonst sperrt ein Test von zu Hause den eigenen
  Zugang — dieselbe Abwägung, die
  [../vm/edge/README.md](../vm/edge/README.md#L267) unter „Was die Kette nicht
  leistet" beschreibt, und dieselbe Folge: LAN-Clients haben die Abwehrschicht
  nicht vor sich.

**Ein bis zwei Wochen im Beobachtungsmodus** fahren, bevor der Bouncer
tatsächlich sperrt.

## 7. Erst jetzt: DNS und Fritzbox

Reihenfolge wie in [INBETRIEBNAHME.md](INBETRIEBNAHME.md) — die Freigabe kommt
zuletzt.

1. `immich.domain.de` und `cloud.domain.de` per DynDNS auf die eigene Adresse,
   über den DNS-Anbieter, nicht über MyFRITZ!.
2. Zertifikate erst gegen das Staging-Verzeichnis holen, dann auf Produktion
   umstellen. Fünf Fehlversuche je Stunde, dann sperrt Let's Encrypt.
3. Fritzbox: **nur 443/TCP auf `192.168.178.232`.** Port 80 bleibt zu, und die
   Freigabe zeigt auf die LoadBalancer-Adresse, nicht auf `lan_ip` des Nodes.
4. **IPv6 getrennt prüfen** — „Host komplett freigeben" öffnet mehr als gedacht.
   UPnP aus, MyFRITZ!-Fernzugriff aus.
5. Interne Namen **nur im Heimnetz** auf `192.168.178.231` auflösen, öffentliche
   Namen im LAN per Split-DNS auf `192.168.178.232`.

## Abnahme

```bash
# Die Adresse der Freigabe bedient nur den öffentlichen Controller
curl -k -H 'Host: dashboard.k8s.nico-steinmueller.de' https://192.168.178.232
#   -> muss im TLS-Handshake enden (sniStrict, kein Default-Zertifikat)

# Ein gefälschter Herkunftsheader darf nicht durchkommen
curl -H 'X-Forwarded-For: 1.2.3.4' https://cloud.domain.de/ >/dev/null
kubectl -n traefik-public logs deploy/traefik-public | tail -5
#   -> im Log steht die echte Peer-IP, nicht 1.2.3.4

# Die echte Client-IP kommt an (externalTrafficPolicy: Local)
#   -> nicht 192.168.178.230

# Die Talos-API ist von einem Nicht-Admin-Host tot
nmap -Pn -p 50000,6443,10250 192.168.178.230

# Ein interner Dienst lässt sich nicht öffentlich schalten
kubectl -n headlamp patch ingress headlamp --type merge \
  -p '{"spec":{"ingressClassName":"public"}}'
#   -> Kyverno lehnt ab; und selbst wenn nicht, bedient ingress-public
#      den Namespace headlamp nicht. Danach zurückpatchen.
```

## Was ersatzlos entfällt

Mit dieser Entscheidung fällt ein großer Teil der offenen Punkte aus
[INBETRIEBNAHME.md](INBETRIEBNAHME.md) weg:

- die gesamte mTLS-Strecke: interne CA, step-ca im Cluster, TCP-Passthrough auf
  Port 9000, `edge-token.sh`, `edge-mtls-bootstrap`, der Erneuerungs-Timer und
  die Entscheidung „Mini-CA oder WireGuard",
- die ACME-DNS-Instanz und die `_acme-challenge`-Delegation (E4/E9),
- das DMZ-Bein am Node und die dazugehörige Ingress-Firewall auf `10.10.20.2`,
  die es in `vm/talos` ohnehin noch nicht gibt,
- die Bootstrap-Schritte 4a bis 4c und `crowdsec_bouncer_armed`,
- der Egress-Filter der Edge und `verify/egress-test.sh`.

Das Modul [../vm/edge](../vm/edge) wird damit nicht mehr angewendet. Es sollte
liegen bleiben, bis der neue Weg zwei Wochen steht — es ist bis dahin der
Rückweg. Danach entweder löschen oder im Kopf der README als „nicht mehr Teil
des Aufbaus" kennzeichnen. Das Sicherheitskonzept braucht dann eine
Überarbeitung von E2 bis E5 und E9.

## Was davon unabhängig offen bleibt

- **Kein Backup.** Weder etcd-Snapshots noch PVC-Sicherung, kein Restore-Test.
  Gehört vor den ersten migrierten Dienst, nicht danach.
- **Der NFS-PV kann nicht mounten.** `unraid-data` zeigt auf `192.168.178.3`,
  den Unraid-Host — und der Node hängt per `macvtap` am LAN, womit VM und
  Hypervisor einander nicht erreichen. Der PVC steht auf `Bound`, aber das ist
  nur die statische Bindung; benutzt hat ihn noch niemand.
- **Keine Benachrichtigung.** `kubectl get alerts,providers` ist leer — ein
  fehlschlagender Reconcile fällt nur auf, wenn jemand nachsieht.
- **Kein CSR-Genehmiger**, deshalb läuft der metrics-server weiter mit
  `--kubelet-insecure-tls`. `kubelet_server_certs` ist in `vm/talos` nicht
  einmal als Variable vorhanden, obwohl INBETRIEBNAHME.md sie beschreibt.
- **Flux synct `refs/heads/kubernetes-try`**, nicht `master`. Vor dem
  Scharfschalten drehen.
