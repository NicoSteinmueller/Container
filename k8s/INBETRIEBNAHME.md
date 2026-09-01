# Inbetriebnahme auf Unraid

Der Weg von einem leeren Unraid-Host zu Immich und Nextcloud im Internet.
Reihenfolge einhalten — die Portfreigabe kommt **zuletzt**, nicht zuerst.

Ausführlich steht alles in [../vm/talos/README.md](../vm/talos/README.md) und
[flux/README.md](flux/README.md); das hier ist der Ablauf.

Was bewusst *nicht* Teil der Inbetriebnahme ist, sondern später kommt, steht in
[AUSBAUSTUFEN.md](AUSBAUSTUFEN.md).

> **Stand: dieses Dokument beschreibt mehr, als es derzeit gibt.**
>
> Die Schritte 0 bis 2 lassen sich heute abarbeiten: Unraid-Host, Talos-Node,
> Flux. Storage, der **interne** Ingress, die LAN-Adressen (Schritt 4) und die
> Umstellung von `ingress-internal` auf LoadBalancer (Schritt 5) sind
> zurückgekommen, als Flux-Manifest statt als Terraform-Modul. Offen sind die
> Ingress-Firewall (Schritt 3) und der Rest des früheren Plattform-Stacks —
> `ingress-public`, Kyverno, CrowdSec. Der lag im Modul `k8s/platform`, ist
> entfernt worden und soll stückweise als Flux-Manifest wiederkommen.
>
> Die betroffenen Schritte bleiben trotzdem hier stehen. Sie beschreiben, was
> der Wiederaufbau zu leisten hat, und die Begründungen darin sind mit dem Code
> nicht ungültig geworden. Was genau fehlt, steht am Ende von Schritt 2.

## Zielbild

Ein Node, zwei LoadBalancer-Adressen aus dem LAN, vergeben von Cilium per
LB-IPAM und im Netz angekündigt per L2-Announcement. Kein `hostPort`, kein
`hostNetwork`, kein Sysctl.

| Adresse | Wer lauscht | Erreichbar von |
|---|---|---|
| `192.168.178.230` | Node selbst: Talos-API, Kubelet, kube-apiserver | nur `admin_sources`, siehe Schritt 3 |
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

Warum der öffentliche Ingress im Cluster steht und nicht auf einer
vorgelagerten VM, und was dieser Verzicht kostet, steht im
[Sicherheitskonzept](homelab-sicherheitskonzept.html) unter **E2**.

## 0. Voraussetzungen auf dem Unraid-Host

| Punkt | Prüfen mit |
|---|---|
| VM-Manager aktiv (Settings → VM Manager → Enable VMs: Yes) | `ssh root@unraid virsh list --all` |
| Anbindung ans LAN: Bridge `br0` **oder** macvtap auf `bond0`/`ethX` | `ssh root@unraid ip -br link` |
| Share `domains` vorhanden, ~120 GB frei | `ssh root@unraid df -h /mnt/cache/domains` |
| RAM-Budget, siehe unten — Container zählen mit | `ssh root@unraid free -m` |

**Zum RAM-Budget.** Die Zahl im Konzept — 10 GB für den Node — beschreibt den
Endausbau, nicht den Tag der Inbetriebnahme. An dem laufen Nextcloud, Immich
und Paperless noch als Container auf dem Host und belegen ihren Speicher weiter:

```
16 GB gesamt  −  ~7,5 GB Docker  =  ~8,5 GB frei
```

**Diese Rechnung ist eine Obergrenze, kein Budget.** Sie unterstellt, dass der
gesamte Rest der VM zusteht — der Host braucht davon aber selbst Page-Cache,
und Unraid hat ab Werk **keinen Swap**. Gemessen mit einer 4-GB-VM: 629 MB
frei, `kswapd0` dauerhaft aktiv, Page-Cache wird laufend verworfen. Darunter
der Kernel-Modul-Squashfs `/boot/bzmodules`, dessen Backing-Store der
USB-Boot-Stick ist. Der stand bei 74 % Auslastung, der ganze Host bei 70 %
iowait und 6 % User-CPU — Load 15,7, ohne dass irgendetwas gerechnet hätte.

Real verfügbar sind eher 2–2,5 GB pro Gigabyte auf dem Papier. Ein Versuch mit
3 GB scheiterte dann aber an der anderen Seite der Rechnung: Der
Plattform-Stack ist nicht „fast nichts". Gemessen im damals laufenden Cluster,
ohne jede Nutzlast, sind es **1900 MiB Memory-Requests** — auf einem Node, dem
Talos von 3072 MiB VM nur 2880 MiB meldet, und der davon selbst rund 600 MiB
für kubelet und containerd braucht. Talos' `runtime.OOMController` schoss
daraufhin reihenweise Cgroups ab.

**Reihenfolge, die dabei zählt:** Der Plattform-Stack muss passen, *bevor* der
erste Dienst migriert. Auf einem 16-GB-Host heißt das, vorher hostseitig Platz
zu schaffen — bei dieser Inbetriebnahme durch das Abschalten von Immich
(~1,9 GB). Die VM startet dann mit **5 GB**.

Erst ab da gilt „pro migriertem Dienst wachsen": Container stoppen, *dann*
`vm_memory_mib` erhöhen, VM neu starten — der Ablauf steht in
[../vm/talos/README.md](../vm/talos/README.md). `memory` ist kein
ForceNew-Feld; die VM wird dabei nicht neu gebaut.

Vor dem Start und vor **jeder** Erhöhung gegenprüfen, was der Host wirklich
frei hat. Maßgeblich ist die Spalte `available`, nicht `free`:

```bash
ssh root@unraid free -m
ssh root@unraid 'docker stats --no-stream --format "{{.Name}}\t{{.MemUsage}}"' | sort -k2 -h
```

Bleibt `available` unter etwa 1,5 GB, ist der nächste Schritt keine Erhöhung,
sondern das Abschalten eines Containers.

**Zum Ablageort der VM-Disks.** Unraid definiert keine libvirt-Storage-Pools —
es schreibt VM-Disks über absolute Pfade ins Domain-XML, `virsh pool-list --all`
ist ab Werk leer. `vm/talos` legt deshalb selbst einen Verzeichnis-Pool an, der
auf den Share `domains` zeigt (`manage_pool`, `pool_path`); von Hand ist dafür
nichts zu tun.

Was dort liegt, sind gewöhnliche qcow2-Dateien — sichtbar in der
Unraid-Oberfläche und für die Backup-Plugins:

```
/mnt/cache/domains/homelab-cp1.qcow2
```

Der Pfad geht bewusst über `/mnt/cache` und nicht über `/mnt/user`: derselbe
Ort, aber ohne die shfs-FUSE-Schicht dazwischen. Das ist kein Feinschliff. Über
`/mnt/user` läuft jeder Blockzugriff der VM durch einen Userspace-Daemon, und
etcd im Talos-Node ruft mehrmals pro Sekunde `fsync` — gemessen rund 40.000
Kontextwechsel/s und 25–32 % Systemzeit auf dem Host, im Leerlauf, ohne eine
einzige Anwendung im Cluster.

Voraussetzung ist, dass der Share cache-only ist — sonst kann der Mover die
Disk aufs Array schieben und `/mnt/cache/domains` zeigt danach ins Leere:

```bash
ssh root@unraid grep shareUseCache /boot/config/shares/domains.cfg   # -> "only"
```

Steht dort etwas anderes, gehört `pool_path` auf `/mnt/user/domains` zurück.

`terraform destroy` meldet den Pool nur ab (`destroy.delete = false`); das
Verzeichnis und alles darin bleiben unangetastet.

**UEFI-Firmware.** Unraids QEMU-Paket liefert den libvirt-Deskriptor
`60-edk2-x86_64.json` mit, der als NVRAM-Vorlage
`/usr/share/qemu/edk2-i386-vars.fd` nennt — diese Datei ist aber nicht dabei.
Die automatische Firmware-Auswahl von libvirt scheitert deshalb mit

```
Failed to open file '/usr/share/qemu/edk2-i386-vars.fd': No such file or directory
```

Unraid bringt stattdessen sein eigenes OVMF mit. In der tfvars-Datei deshalb
setzen:

```hcl
efi_loader        = "/usr/share/qemu/ovmf-x64/OVMF_CODE-pure-efi.fd"
efi_vars_template = "/usr/share/qemu/ovmf-x64/OVMF_VARS-pure-efi.fd"
```

Gegenprüfen mit `ssh root@unraid ls /usr/share/qemu/ovmf-x64/`. Den
Variablenspeicher je VM legt libvirt daraus in `/etc/libvirt/qemu/nvram` an
(`nvram_dir`) — das liegt bei Unraid in `libvirt.img` und überlebt Neustarts.

**Bridge oder macvtap.** Unraid legt `br0` nur an, wenn *Bridging* in den
Netzwerkeinstellungen aktiv ist. Ist es das nicht — bei neueren Installationen
der Normalfall, weil Docker dort mit macvlan arbeitet —, gibt es nur `bond0`
bzw. `eth0`, und der VM-Start scheitert mit

```
Cannot get interface MTU on 'br0': No such device
```

Dann statt `lan_bridge` setzen:

```hcl
lan_macvtap_dev = "bond0"     # ip -br link auf dem Host zeigt den Namen
```

Was das bedeutet, und das ist kein Detail: Mit macvtap erreichen sich VM und
Hypervisor-Host **nicht**. Zwei Folgen muss man kennen:

- **Der interne Resolver darf nicht auf dem Host selbst liegen.** Läuft
  AdGuard als Docker-Container in einem macvlan-Netz (auf Unraid der
  Netzwerktyp `bond0`), hat er eine eigene LAN-Adresse und ist erreichbar —
  genau die gehört in `dns_servers`, nicht die Adresse des Unraid-Hosts.
- **NFS-Exporte vom selben Host sind über dieses Bein nicht erreichbar.**
  Solange die PVCs auf der VM-Disk liegen (local-path), ist das egal; sobald
  die Nutzerdaten auf das Array wandern, ist es der Punkt, an dem entweder
  Bridging eingeschaltet oder ein zweites Bein ergänzt werden muss. Zu
  entscheiden ist das, *bevor* die StorageClass zurückkommt — danach hängen
  Daten daran.

**SSH-Key nach Unraid.** Terraform spricht über `qemu+ssh://root@…` mit
libvirt. Unraid bootet vom USB-Stick, `/root` ist ein RAM-Dateisystem — ein
`ssh-copy-id` überlebt den nächsten Neustart nicht. Der Key gehört deshalb
zusätzlich nach `/boot/config/ssh/root.pubkeys` — Unraid kopiert die Datei ab
6.10 beim Booten nach `/root/.ssh/authorized_keys`. Bei älteren Versionen
stattdessen eine Zeile in `/boot/config/go`:

```bash
ssh-copy-id root@192.168.178.3                     # für jetzt
ssh root@192.168.178.3 'mkdir -p /boot/config/ssh && \
  cat /root/.ssh/authorized_keys >> /boot/config/ssh/root.pubkeys'   # für später
```

**Auf der Arbeitsstation:** `tofu`, `talosctl`, `kubectl`, `helm`.

`tofu`, `talosctl`, `age` und `sops` kommen aus dem Tools-Playbook, nicht von
Hand — dort steht der Versions-Pin, den Renovate anhebt, und die Prüfsumme
zieht die Rolle aus dem Release:

```bash
cd ansible/tools
ansible-playbook -i inventory.ini tools.yml --ask-become-pass
```

Der Pin von `talosctl` muss zur `talos_version` in
[../vm/talos/variables.tf](../vm/talos/variables.tf) passen; er steht in
[../ansible/tools/roles/talosctl/defaults/main.yml](../ansible/tools/roles/talosctl/defaults/main.yml).

**Adressen festlegen** (Beispiel, muss zum eigenen Netz passen):

| Was | Adresse | Wo eingetragen |
|---|---|---|
| Unraid | 192.168.178.3 | — |
| Interner Resolver (AdGuard) | eigene LAN-Adresse des Containers, **nicht** die des Hosts | `dns_servers` in vm/talos |
| Talos-Node, LAN | 192.168.178.230 | `lan_ip` in vm/talos |
| `ingress-internal` | 192.168.178.231 | LB-IPAM-Pool, Schritt 4 |
| `ingress-public` | 192.168.178.232 | LB-IPAM-Pool, Schritt 4; Ziel der Fritzbox-Freigabe |

Alle drei Adressen müssen **außerhalb** des Fritzbox-DHCP-Bereichs liegen.

## 1. Talos-Node

```bash
cd vm/talos
cp terraform.tfvars.example terraform.tfvars
```

Anpassen:

```hcl
# Die wichtigste Zeile: ohne sie baut Terraform alles auf der eigenen
# Arbeitsstation statt auf Unraid.
libvirt_uri     = "qemu+ssh://root@192.168.178.3/system"
lan_macvtap_dev = "bond0"          # oder lan_bridge, je nach Host
lan_ip          = "192.168.178.230"
lan_gateway     = "192.168.178.1"
dns_servers     = ["192.168.178.2"]
admin_sources   = ["192.168.178.50/32"]   # die eigene Arbeitsstation

efi_loader        = "/usr/share/qemu/ovmf-x64/OVMF_CODE-pure-efi.fd"
efi_vars_template = "/usr/share/qemu/ovmf-x64/OVMF_VARS-pure-efi.fd"

vm_memory_mib = 5120               # Startwert, siehe RAM-Budget oben
```

```bash
terraform init && terraform apply       # 5-10 Minuten, wartet auf einen gesunden Cluster
export TALOSCONFIG=$PWD/talosconfig KUBECONFIG=$PWD/kubeconfig
kubectl get nodes -o wide               # Ready, INTERNAL-IP 192.168.178.230
verify/assert-cluster.sh
```

**Wenn `talos_machine_configuration_apply` minutenlang „Still creating…" meldet**
und die VM auf Unraid trotzdem als gestartet erscheint, ist der Node im
Maintenance-Mode nicht unter `lan_ip` erreichbar. Nachsehen:

```bash
ping -c2 192.168.178.230                    # keine Antwort?
ip -4 neigh show | grep 52:54:00:7a:20:01   # welche Adresse hat er wirklich?
```

Das Modul gibt dem Image dafür einen `ip=`-Kernel-Parameter mit, damit die
feste Adresse schon vor dem ersten Apply steht (`maintenance_link` in
[../vm/talos/variables.tf](../vm/talos/variables.tf)). Steht dort trotzdem eine
DHCP-Adresse, passt der Interface-Name nicht — am laufenden Node prüfen und
`maintenance_link` korrigieren:

```bash
talosctl get links --insecure -n <gefundene-adresse> -e <gefundene-adresse>
```

Sonst hilft die serielle Konsole:
`virsh -c qemu+ssh://root@192.168.178.3/system console homelab-cp1`.

## 2. Cluster ausstatten

Was im Cluster läuft, kommt aus zwei Quellen: Flux selbst per tofu, alles
Weitere als Manifest aus Git. Werte und State liegen in Gitea, deshalb der
Wrapper statt eines nackten `tofu`.

```bash
cd ../../k8s/flux
git -C "$HOMELAB_VALUES" pull
../../tools/tf init
../../tools/tf apply
```

Danach die drei Bootstrap-Geheimnisse eintragen — drei `kubectl patch`, die
Befehle und ihre Begründung stehen in [flux/README.md](flux/README.md),
Abschnitt Secrets. Ohne sie erreicht Flux das Repo `homelab-secrets` nicht.

```bash
kubectl -n flux-system get fluxinstance,gitrepository,kustomization,helmrelease
```

Alles auf `Ready`, dann laufen whoami, Headlamp, metrics-server und Reloader.

### Was an dieser Stelle fehlt

Bis vor Kurzem stand hier das Modul `k8s/platform`: Namespaces,
NetworkPolicies, IngressClasses, local-path-provisioner, cert-manager, step-ca,
Traefik als `public`/`internal`, Kyverno, CrowdSec und der kubelet-csr-approver.
Es ist entfernt worden und kommt stückweise als Flux-Manifest zurück.

**Zurück sind:** Storage (`local-path.yaml`, `nfs-storage.yaml`), der interne
Ingress mit Namespaces, NetworkPolicies und der IngressClass `internal`
(`ingress-internal.yaml`) sowie die LAN-Adressen (`lb-ipam.yaml`, Schritt 4).
Damit sind drei der früheren Sperren weg: PVCs binden, Dienste hängen unter
Hostnamen statt an NodePorts, und ein Service vom Typ `LoadBalancer` bekommt
eine Adresse, die im Netz auch angekündigt wird. Der interne Controller nimmt
sie seit Schritt 5 auch in Anspruch — er hängt auf `.231` statt am hostPort.

**Noch offen, und was daran hängt:**

- **Keine Ingress-Firewall auf dem Node.** `talosctl get nftableschains` kommt
  leer zurück, `admin_sources` gibt es in `vm/talos` noch nicht. Das ist
  Schritt 3 und muss stehen, bevor die Fritzbox irgendetwas weiterleitet.
- **Kein `ingress-public`.** Die Klasse `public` existiert nicht, eine
  Portfreigabe führte ins Leere. Schritt 8.
- **Kein Kyverno.** Die Regel auf `ingressClassName: public` gibt es damit
  nicht. Solange die Klasse `public` gar nicht existiert, fehlt ihr auch der
  Anwendungsfall — mit ihr wird die Regel tragend, siehe Schritt 9. Die
  Reloader-Annotation, die Kyverno ebenfalls setzte, wird nicht mehr gebraucht
  (siehe [flux/README.md](flux/README.md), Abschnitt Rotation).
- **Kein CrowdSec.** Weder LAPI noch Agent noch Bouncer. Schritt 10.
- **Kein CSR-Genehmiger.** `kubelet_server_certs` in `vm/talos` muss aus
  bleiben, sonst bricht der Apply dort ab.

## 3. Talos-Ingress-Firewall

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

## 4. Cilium: LB-IPAM und L2-Announcements

**Gemessen und bestaetigt — die Umstellung ist gangbar.** Was hier lange als
offene Frage stand, ist beantwortet: Gratuitous ARP fuer eine Zusatzadresse
traegt ueber das macvtap-Interface des Nodes. Der Beweis steht unten unter
Gegenprobe.

Die Voraussetzung war erfuellt — `kubeProxyReplacement: true` steht in
[../vm/talos/values/cilium.yaml.tftpl](../vm/talos/values/cilium.yaml.tftpl),
Cilium laeuft als v1.20.1. Dazugekommen sind in denselben Werten:

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

> **Und damit ist es noch nicht im Cluster.** Talos schreibt geaenderte
> Inline-Manifeste nicht auf bereits bestehende Objekte durch: `tofu plan`
> sagt danach `No changes`, `talosctl get manifests` zeigt `99-cilium` mit
> erhoehter `VERSION` — und die ConfigMap im Cluster hat den neuen Wert
> trotzdem nicht. Der Nachtrag von Hand steht in
> [../vm/talos/README.md](../vm/talos/README.md) unter *Eine Wertaenderung ist
> mit `tofu apply` nicht im Cluster*. Gegenprobe hier:
>
> ```bash
> kubectl -n kube-system get cm cilium-config \
>   -o jsonpath='{.data.enable-l2-announcements}{"\n"}'        # true
> kubectl get clusterrole cilium -o yaml | grep -A3 coordination  # leases
> ```

> **Nicht per `kubectl patch cm cilium-config` abkuerzen.** Der Wert
> `l2announcements.enabled` setzt zweierlei: das Agent-Flag
> `enable-l2-announcements` **und** die RBAC-Regeln auf
> `coordination.k8s.io/leases`. Wer nur das Flag in der ConfigMap setzt,
> bekommt einen Agent, der ankuendigen will und nicht darf — im Log eine
> Endlosschleife aus
> `leases.coordination.k8s.io "cilium-l2announce-..." is forbidden`, nach
> aussen ein Service mit `EXTERNAL-IP`, den niemand erreicht.

Dazu das Flux-Manifest
[flux/clusters/talos-cp1/lb-ipam.yaml](flux/clusters/talos-cp1/lb-ipam.yaml):
der `CiliumLoadBalancerIPPool` mit `.231`–`.232` und die
`CiliumL2AnnouncementPolicy` auf `enp1s0`. Begruendungen stehen als Kommentare
in der Datei; zwei Dinge, die beim Abschreiben aus der Cilium-Doku auffallen:

- **Die beiden CRs haben verschiedene apiVersions.** Beim
  `CiliumLoadBalancerIPPool` ist `cilium.io/v2` die Storage-Version, `v2alpha1`
  quittiert das Apply mit einer Deprecation-Warnung. Die
  `CiliumL2AnnouncementPolicy` kennt in 1.20.1 **kein** `v2` und bleibt bei
  `v2alpha1`. Beim Cilium-Update mitpruefen.
- **Welcher Service welche Adresse bekommt, entscheidet der Pool nicht.** Das
  regelt die Annotation `lbipam.cilium.io/ips` am Service (Schritt 5). Ohne sie
  waere die Zuordnung die Reihenfolge der Vergabe — und ein Neustart koennte
  die beiden Ingress-Adressen tauschen, mitten in einer bestehenden
  Portfreigabe.

### Gegenprobe — mit einem Wegwerf-Dienst, und vom richtigen Rechner aus

Zwei Fallen stecken in dieser Messung, und beide liefern ein **falsches
Negativ**: Man misst nichts, glaubt aber, die Ankuendigung sei kaputt.

**Nicht `whoami` nehmen.** Dessen Namespace traegt `whoami-default-deny` plus
eine Regel, die ausschliesslich `traefik-internal` auf Port 80 zulaesst. Ein
`curl` direkt auf die LB-Adresse wird von der NetworkPolicy verworfen — auch
bei tadellos funktionierendem L2. Deshalb ein eigener Namespace ohne Policy.

**Nicht von einem Rechner messen, dessen Weg ins LAN ueber einen Tunnel
fuehrt.** Ein VPN-Interface zur Fritzbox ist `POINTOPOINT,NOARP` und hat oft
die kleinere Metrik als das echte LAN-Interface — dann macht die Fritzbox das
ARP, nicht der messende Rechner, und der Test sagt nichts ueber das Segment
aus. Gegenprobe vorweg: `ip route get 192.168.178.230` muss ein echtes
Ethernet-Interface nennen. Der Unraid-Host selbst ist der sichere Ort dafuer.

```bash
kubectl create namespace l2-test
kubectl -n l2-test create deployment l2-test --image=traefik/whoami:v1.12.0 \
  -- /whoami --port=8080
kubectl -n l2-test expose deployment l2-test --type=LoadBalancer \
  --port=80 --target-port=8080 \
  --overrides='{"metadata":{"annotations":{"lbipam.cilium.io/ips":"192.168.178.231"}},"spec":{"externalTrafficPolicy":"Local"}}'

kubectl -n l2-test get svc l2-test          # EXTERNAL-IP muss vergeben werden
kubectl -n kube-system get lease | grep l2announce   # muss existieren

# Vom Unraid-Host, nicht vom Arbeitsrechner:
ssh root@192.168.178.3 'curl -s --max-time 8 http://192.168.178.231; \
  ip neigh show 192.168.178.231'

kubectl delete namespace l2-test
```

Zwei Zeilen entscheiden. Die MAC zu `.231` muss **dieselbe** sein wie die zu
`.230` — dann kuendigt der Node an, und macvtap laesst es durch:

```
192.168.178.231 dev vhost0 lladdr 52:54:00:7a:30:01 REACHABLE
192.168.178.230 dev vhost0 lladdr 52:54:00:7a:30:01 STALE
```

Und im `whoami`-Ausgabeblock zeigt `RemoteAddr` die Adresse des *Aufrufers*
(hier `192.168.178.3`), nicht die des Nodes. Das ist die Vorwegnahme von
`externalTrafficPolicy: Local` aus Schritt 5: kein SNAT, die Client-Adresse
ueberlebt.

Fehlt die Lease, ist es RBAC (siehe Kasten oben), nicht das Netz:

```bash
kubectl -n kube-system logs ds/cilium | grep -i "l2announce\|forbidden" | tail
```

Kaeme hier wirklich nichts an, waere die ganze Umstellung blockiert — dann
bliebe nur der Weg ueber `hostIP` mit `hostNetwork` (samt der Policy-Folge aus
dem Zielbild) oder ein zweites virtuelles Interface. Dieser Fall ist mit der
Messung oben ausgeschlossen.

## 5. `ingress-internal` auf LoadBalancer umstellen

In [flux/clusters/talos-cp1/ingress-internal.yaml](flux/clusters/talos-cp1/ingress-internal.yaml):

```yaml
service:
  enabled: true
  annotations:
    lbipam.cilium.io/ips: "192.168.178.231"
  spec:
    # `type` gehört in 41.3.0 in den spec-Block, nicht daneben: Das Chart
    # kennt kein `service.type` mehr und schreibt spec unverändert durch.
    type: LoadBalancer
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

Zu entfernen: beide `hostPort`-Zeilen.

**`updateStrategy: Recreate` bleibt trotzdem stehen.** Sein bisheriger Grund
fällt weg — der Scheduler behandelt hostPorts wie NodePorts, der neue Pod
blieb Pending. Ein zweiter tritt an seine Stelle: `acme.json` liegt auf einem
`ReadWriteOnce`-PVC, das local-path auf genau diesem Node hält. Zwei Pods
dürfen es damit gleichzeitig mounten, und lego schreibt die Datei ohne Sperre —
ein überlappender Rollout kann das Wildcard zerschreiben, mit den Rate Limits
von Let's Encrypt im Rücken.

**`externalTrafficPolicy: Local` ist keine Feinheit.** Ohne sie wird die
Client-Adresse per SNAT auf die Node-Adresse ersetzt. Dann trägt das Paket die
Cilium-Identität `host` statt `world` — und damit greift die NetworkPolicy
`allow-from-lan` nicht mehr, aus genau dem Grund, den der Kommentar in derselben
Datei beschreibt (Cilium wertet `ipBlock` nicht gegen `host` und `remote-node`
aus). Zusätzlich sähe CrowdSec später überall dieselbe Quell-IP.

**Ein Eintrag kommt hinzu, den man leicht übersieht:** `traefik-internal`
gehört jetzt in `providers.kubernetesIngress.namespaces`. Mit dem Service setzt
das Chart `ingressendpoint.publishedservice`, und Traefik trägt dessen Adresse
in `status.loadBalancer` jedes Ingress ein — die ADDRESS-Spalte von `kubectl get
ingress`. Dafür muss es den eigenen Service lesen dürfen, und der
Ingress-Provider liest nur in den gelisteten Namespaces. Sonst im Log:
`cannot get service traefik-internal/traefik-internal: namespace is not within
watched namespaces`.

Zwei Aufräumarbeiten, die jetzt möglich werden:

- Der ausführliche Kommentarblock zu `hostPort`/`hostNetwork`/Sysctl ist
  gegenstandslos und sollte durch die Begründung für LoadBalancer ersetzt
  werden — nicht gelöscht, ersetzt.
- Das PodSecurity-Label des Namespace steht auf `enforce: privileged`, **nur**
  weil hostPorts ab `baseline` als Verstoß zählen. Ohne hostPort kann es zurück;
  der Pod läuft ohnehin als 65532 mit `readOnlyRootFilesystem`, gedroppten
  Capabilities und `RuntimeDefault`-Seccomp. Auf `restricted` stellen und den
  Rollout beobachten.

Abnahme:

```bash
kubectl -n traefik-internal get svc traefik-internal   # EXTERNAL-IP 192.168.178.231
kubectl -n traefik-internal get pod                    # laeuft unter PodSecurity restricted
curl -sI https://192.168.178.231 -k --resolve dashboard.k8s.nico-steinmueller.de:443:192.168.178.231 \
     https://dashboard.k8s.nico-steinmueller.de
```

Dann `https://dashboard.k8s.nico-steinmueller.de` — löst weiter auf und
antwortet, der DNS-Eintrag muss dabei von `.230` auf `.231` umgezogen werden.
Zuletzt gegenprüfen, dass `.230` die Ports 80/443 **nicht** mehr bedient:
`nmap -Pn -p 80,443 192.168.178.230`.

## 6. Dashboard und Metriken

Das Dashboard steht mit Schritt 2 schon und hängt seit `ingress-internal.yaml`
unter seinem Hostnamen, nicht mehr am NodePort `30080`. Aufrufen unter
`https://dashboard.<interne-domain>` — und dort nach einem Token gefragt
werden:

```bash
# Der Alltagsfall: lesen. Kommt an keine Secrets.
kubectl -n headlamp create token headlamp --duration=8h

# Nur wenn im Dashboard geändert werden soll. Läuft nach einer Stunde ab.
kubectl -n headlamp create token headlamp-admin --duration=1h
```

Die Anmeldung ist hier die Kontrolle, nicht die Netzgrenze: Headlamp spricht
mit genau der Identität mit der API, zu der das eingefügte Token gehört. Wer
die Adresse ohne Token aufruft, sieht nichts.

**Die Auslastungsanzeigen laufen ebenfalls schon** — der metrics-server kommt
als HelmRelease aus Schritt 2:

```bash
kubectl top node
kubectl top pod -A
```

**Dass das ohne weiteres Zutun geht, ist eine bewusste Abkürzung.** Der
metrics-server läuft mit `--kubelet-insecure-tls`, spricht das Kubelet also
über eine verschlüsselte, aber ungeprüfte Verbindung an — und zwar genau die
Komponente, die Auskunft über jeden Pod auf dem Node gibt. Die Begründung, und
warum sie im LAN vertretbar ist, steht in
[flux/clusters/talos-cp1/metrics-server.yaml](flux/clusters/talos-cp1/metrics-server.yaml).

Der saubere Weg braucht drei Teile, von denen einer fehlt: ein prüfbares
Serverzertifikat vom Kubelet (`kubelet_server_certs` in `vm/talos`), einen
Genehmiger für die Zertifikatsanträge im Cluster (kubelet-csr-approver, kam
aus `k8s/platform`) und einen Neustart des Nodes dazwischen.

**Die Reihenfolge ist dabei keine Feinheit, sondern eine Falle.** Wird die
Talos-Zeile gesetzt, *bevor* der Genehmiger läuft, bricht der Apply dort ab mit
*„kubelet server certificate rotation is enabled, but CSR is not approved"* —
und `kubectl logs` und `kubectl exec` funktionieren bis dahin nicht mehr.
Solange der Genehmiger fehlt, bleibt `kubelet_server_certs` deshalb aus.

Wenn er wieder da ist:

```bash
kubectl -n kube-system get deploy kubelet-csr-approver   # muss laufen

cd vm/talos
vim "$HOMELAB_VALUES/vm/talos/terraform.tfvars"   # kubelet_server_certs = true
../../tools/tf apply
talosctl -n <node-ip> reboot

kubectl get csr                                   # nichts auf "Pending"
```

Danach `--kubelet-insecure-tls` aus den Werten des metrics-server nehmen.

## 7. Anwendungen

> **Gesperrt, solange keine StorageClass da ist.** Ohne sie bleibt jeder PVC
> `Pending`, und kein Dienst mit Daten kommt hoch — siehe Ende von Schritt 2.
> Der Abschnitt zum RAM weiter unten gilt unabhängig davon.

Namespaces, NetworkPolicies und die Klasse `internal` stehen wieder; ein
Ingress braucht nur noch die richtige Klasse:

```yaml
spec:
  ingressClassName: internal   # paperless          -> nur aus dem LAN
  # ingressClassName: public   # nextcloud, immich  -> aus dem Internet
```

`public` ist dabei noch keine Option: Die Klasse existiert nicht, solange
`ingress-public` fehlt (Schritt 8). Und zwei Handgriffe kommen je Dienst dazu,
die es früher nicht gab — beide wegen `rbac.namespaced` am Controller:

- der neue Namespace muss an drei Stellen in
  [flux/clusters/talos-cp1/ingress-internal.yaml](flux/clusters/talos-cp1/ingress-internal.yaml)
  stehen: `providers.kubernetesIngress.namespaces`,
  `providers.kubernetesCRD.namespaces` und eine RoleBinding auf die ClusterRole
  `traefik-internal-namespaced`,
- und er braucht eine NetworkPolicy, die `traefik-internal` hereinlässt —
  sonst greift sein eigenes Default-Deny.

**Jeder Dienst kommt zuerst über `ingress-internal` hoch**, auch die beiden,
die später öffentlich werden. Erst wenn er dort steht und die Daten stimmen,
ist Schritt 8 überhaupt sinnvoll.

**Pro migriertem Dienst, in dieser Reihenfolge:**

```bash
# 1. Im Cluster hochziehen, Daten übernehmen, über ingress-internal prüfen
# 2. Erst dann den Container auf dem Host stoppen - jetzt ist der RAM frei
ssh root@unraid docker stop nextcloud nextcloud_postgres nextcloud_redis

# 3. RAM der VM nachziehen
cd vm/talos && vim terraform.tfvars     # vm_memory_mib erhöhen
terraform apply                         # in-place, kein Neubau

# 4. Wirksam beim nächsten Start
talosctl -n 192.168.178.230 shutdown
ssh root@unraid virsh start homelab-cp1
```

Schritt 2 vor Schritt 3, nicht umgekehrt: Sonst konkurrieren Container und VM
um denselben Speicher, und auf einem Host ohne Swap holt sich der OOM-Killer
den größten Prozess — das ist qemu, also der ganze Cluster.

Den Container erst löschen, wenn der Dienst im Cluster ein paar Tage steht.
Bis dahin ist er der Rückweg.

## 8. `ingress-public` bauen

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
   ist der Grund, warum ein einzelner Fehler im Manifest eines internen Dienstes
   ihn nicht exponiert.
4. **Kein Zugriff auf das interne Wildcard.** Eigener `certResolver`, eigener
   PVC für den ACME-Speicher, Zertifikate je Name über DNS-01 für die
   öffentliche Zone. Das Wildcard `*.k8s.nico-steinmueller.de` bleibt im
   Namespace `traefik-internal` und wird dort nicht herausgereicht — E10
   sinngemäß. **Offen dabei:** Der Controller hält damit einen
   DNS-Provider-Token in der exponierten Zone. Die beiden möglichen
   Auflösungen — ACME-DNS-Delegation oder ein von cert-manager geliefertes
   Secret — stehen im [Sicherheitskonzept](homelab-sicherheitskonzept.html)
   unter E4; entschieden ist keine.
5. **Die Verarbeitungskette am Entrypoint `websecure`**, als dynamische
   Konfiguration: `sniStrict: true` ohne `defaultCertificate` (fremde Namen
   enden im Handshake), `strip-client-forwarded` gegen gefälschte
   Herkunftsheader, `forwardedHeaders.trustedIPs: []` (vor diesem Controller
   steht kein Proxy), HSTS, und die drei Ratelimit-Stufen. Der laufende
   Docker-Stand in [../traefik/](../traefik/) ist dafür die Vorlage.

NetworkPolicies im neuen Namespace:

```
default-deny-ingress          wie im internen Namespace
allow-from-world              ingress auf 8000/8443 ohne ipBlock-Einschränkung
allow-to-served-namespaces    egress nur zu immich/nextcloud und kube-dns
allow-to-crowdsec-lapi        egress auf die LAPI, Port und Namespace benannt
```

Und je öffentlichem Dienst — wie beim internen Controller — eine
NetworkPolicy im Ziel-Namespace, die `traefik-public` hereinlässt.

## 9. Kyverno — tragend, nicht ergänzend

Es gibt nur noch **eine** unabhängige Sperre gegen „privater Dienst
versehentlich öffentlich": die Namespace-Liste aus Schritt 8. **Kyverno gehört
deshalb vor den ersten öffentlichen Dienst, nicht danach.**

Regel: `ingressClassName: public` nur in Namespaces mit dem Label
`exposure: public`. Damit muss ein Versehen an zwei Stellen gleichzeitig
passieren — Label am Namespace **und** Eintrag in der Namespace-Liste —, und
beide stehen in Git und sind im Review sichtbar.

Die Reloader-Annotation, die Kyverno früher ebenfalls setzte, wird nicht mehr
gebraucht; siehe [flux/README.md](flux/README.md), Abschnitt Rotation.

## 10. CrowdSec im Cluster

Alle Bausteine sind aus dem Docker-Stand übernehmbar; die Collection-Liste steht
fertig in [../traefik/compose.yml](../traefik/compose.yml).

- **LAPI in einem eigenen Namespace** `crowdsec`, **nicht** in `traefik-public`.
  Das ist E7 eine Ebene tiefer: Die exponierte Komponente darf Entscheidungen
  nicht löschen. Der Bouncer-Key ist lesend, die NetworkPolicy der LAPI lässt
  nur `traefik-public` auf den einen Port.
- **Agent** liest die Traefik-Logs von `ingress-public`, plus die Logs der
  Anwendungen dort, wo sie entstehen.
- **AppSec-Listener** mit `crowdsecurity/appsec-virtual-patching`,
  `appsec-crs` und der Nextcloud-Exclusion — zwei Listener: Virtual Patching
  plus CRS für die strengen Pfade, Virtual Patching allein für
  `/remote.php/*`.
- **Bouncer** als Traefik-Plugin-Middleware am öffentlichen Entrypoint.
  `clientTrustedIPs` auf das LAN, sonst sperrt ein Test von zu Hause den eigenen
  Zugang. Die Folge davon ist bekannt und gewollt: LAN-Clients haben die
  Abwehrschicht nicht vor sich, siehe „Restrisiken" im
  [Sicherheitskonzept](homelab-sicherheitskonzept.html).

**Der Bouncer sperrt zunächst nicht.** Ein bis zwei Wochen Beobachtungsmodus,
dann Schritt 12.

## 11. Erst jetzt: DNS und Fritzbox

Die Freigabe kommt zuletzt.

1. `immich.domain.de` und `cloud.domain.de` per DynDNS auf die eigene Adresse,
   über den DNS-Anbieter, nicht über MyFRITZ!.
2. Zertifikate erst gegen das Staging-Verzeichnis holen, dann auf Produktion
   umstellen. Fünf Fehlversuche je Stunde, dann sperrt Let's Encrypt.
3. Fritzbox: **nur 443/TCP auf `192.168.178.232`.** Port 80 bleibt zu, und die
   Freigabe zeigt auf die LoadBalancer-Adresse, nicht auf `lan_ip` des Nodes.
4. **IPv6 getrennt prüfen** — „Host komplett freigeben" öffnet mehr als gedacht.
   UPnP aus, MyFRITZ!-Fernzugriff aus.
5. Interne Namen **nur im Heimnetz** auf `192.168.178.231` auflösen (AdGuard
   oder Fritzbox), öffentliche Namen im LAN per Split-DNS auf
   `192.168.178.232`. Im öffentlichen DNS haben die internen Namen nichts
   verloren. Gibt es dort schon einen Wildcard-Eintrag auf den Unraid-Host,
   müssen diese Namen explizit gesetzt werden — sonst landen sie beim Traefik
   im Docker-Netz des Hosts.

### Abnahme

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

## 12. Scharfschalten (nach 1-2 Wochen)

```bash
kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli alerts list
```

Sind die Alarme plausibel und ist nichts aus dem eigenen Netz darunter, den
Bouncer aus dem Beobachtungsmodus nehmen und die Sperre einschalten. Danach
noch einmal von außen prüfen, dass ein absichtlich falscher Login tatsächlich
gebannt wird — und dass der eigene LAN-Zugang davon unberührt bleibt.

## Wenn etwas klemmt

| Symptom | Erste Stelle |
|---|---|
| `terraform apply` kommt nicht an libvirt | `virsh -c qemu+ssh://root@unraid/system list` von Hand |
| `Failed to open file '…edk2-i386-vars.fd'` | `efi_loader`/`efi_vars_template` setzen, siehe Abschnitt 0 |
| `AppArmor-Profil … kann nicht geladen werden` | Der Apply läuft gegen den **lokalen** libvirt — `libvirt_uri` in der tfvars fehlt. `terraform destroy`, URI setzen, erneut anwenden |
| `Cannot get interface MTU on 'br0'` | Kein Bridging auf dem Host — `lan_macvtap_dev = "bond0"` statt `lan_bridge` |
| `talos_machine_configuration_apply` hängt, VM läuft aber | Node hat im Maintenance-Mode eine DHCP-Adresse statt `lan_ip` — siehe Schritt 1 |
| `data.talos_cluster_health` läuft in den Timeout, `talosctl` antwortet aber | Control Plane startet nicht. `talosctl -n … containers -k` zeigt `CONTAINER_EXITED`, die Begründung steht in `talosctl -n … logs -k kube-system/kube-apiserver-<node>:kube-apiserver` |
| Static Pod neu gerendert, aber kein neuer Startversuch | Kubelet hängt: `talosctl -n … service kubelet restart` |
| Talos bleibt NotReady | `kubectl -n kube-system get pods -l k8s-app=cilium`, `talosctl -n … dmesg` |
| Dienst über NodePort im Timeout, Service und Endpoint sehen gesund aus | Fast immer eine NetworkPolicy, oft eine vom Chart mitgebrachte — mit Cilium werden sie erstmals durchgesetzt, unter Flannel waren sie wirkungslos. `kubectl -n kube-system exec ds/cilium -- hubble observe --last 200 --type drop`; Quelle `(world)` heißt: Regel ohne `ipBlock` erfasst LAN-Clients nicht |
| Node nicht mehr erreichbar | `admin_sources` falsch → serielle Konsole, siehe vm/talos/README.md |
| LoadBalancer-Service bleibt ohne `EXTERNAL-IP` | Kein passender `CiliumLoadBalancerIPPool`, oder die Adresse liegt außerhalb des Blocks. `kubectl get ciliumloadbalancerippool`, `kubectl describe svc <name>` |
| `EXTERNAL-IP` steht, antwortet aber nicht | L2-Announcement kommt nicht durch. `ip -4 neigh show \| grep <adresse>` von einem LAN-Rechner — steht dort nicht die MAC des Nodes, stimmt `interfaces` in der `CiliumL2AnnouncementPolicy` nicht, oder macvtap schluckt das Gratuitous ARP |
| Im Log steht überall die Node-Adresse als Client-IP | `externalTrafficPolicy: Local` fehlt am Service — siehe Schritt 5 |
| ACME schlägt fehl | Zeit (NTP), DNS-Provider-Credentials, Staging-Verzeichnis verwenden |
| `HelmRelease` oder `Kustomization` bleibt auf `False` | `kubectl -n flux-system describe helmrelease <name>`; bei `homelab-secrets` fast immer die drei Bootstrap-Secrets, siehe [flux/README.md](flux/README.md) |
| Secret im Cluster enthält wörtlich `ENC[AES256_GCM,…]` | Der `decryption`-Block der Kustomization greift nicht — der age-Schlüssel in `sops-age` passt nicht zu `.sops.yaml` |
| PVC bleibt `Pending` | Es gibt keine StorageClass, siehe Ende von Schritt 2. `kubectl get storageclass` ist leer |
| Ingress antwortet nicht | `kubectl -n traefik-internal logs deploy/traefik-internal`. Kommt dort nichts an, ist es fast immer die NetworkPolicy: `kubectl -n kube-system exec ds/cilium -- hubble observe --last 200 --type drop`. Notbremse: `kubectl -n traefik-internal delete networkpolicy allow-from-lan` |
| Ingress wird gar nicht bedient, Objekt sieht richtig aus, Traefik antwortet mit 404 | Zwei Kandidaten: Sein Namespace fehlt in `providers.kubernetesIngress.namespaces` oder hat keine RoleBinding. Oder — falls jemand `rbac.namespaced: true` gesetzt hat — greift `spec.ingressClassName` gar nicht mehr, siehe Abschnitt „RBAC von Hand" in [flux/clusters/talos-cp1/README.md](flux/clusters/talos-cp1/README.md) |
| `RoleBinding ... cannot change roleRef` beim Apply | Eine gleichnamige Bindung zeigt noch auf eine `Role` statt auf die `ClusterRole`. `roleRef` ist unveränderlich — alte löschen oder unter eigenem Namen anlegen |
| Traefik in CrashLoop mit `bind: permission denied` | Es läuft noch mit `hostNetwork` statt über den LoadBalancer-Service — dann braucht der Node den Sysctl `net.ipv4.ip_unprivileged_port_start=0`. Der Weg dahin zurück ist Schritt 5 |
| Browser warnt vor dem Zertifikat | Steht `caServer` noch auf dem Staging-Verzeichnis? Dessen Wurzel kennt kein Browser. Sonst: `kubectl -n traefik-internal logs deploy/traefik-internal \| grep -i acme` |
| ACME schlägt fehl mit DNS-Fehlern | IONOS-API-Key prüfen (`traefik-ionos` in homelab-secrets, Format `<prefix>.<secret>`). Vorsicht mit Wiederholungen: fünf Fehlversuche je Stunde, dann sperrt Let's Encrypt |
| Alles tot nach Policy-Änderung *(ingress-public, sobald es steht)* | `kubectl -n traefik-public delete networkpolicy allow-from-world` |
| `kubectl logs`/`exec` brechen weg, Node ist aber Ready | Kubelet-CSR ungenehmigt. `kubectl get csr`, dann `kubectl -n kube-system logs -l app.kubernetes.io/name=kubelet-csr-approver`. Notbremse: `kubelet_server_certs = false` in `vm/talos`, apply, reboot |
| `apply` in `vm/talos` bricht ab mit „kubelet server certificate rotation is enabled, but CSR is not approved" | `kubelet_server_certs` wurde gesetzt, ohne dass ein CSR-Genehmiger im Cluster läuft — den gibt es derzeit nicht, siehe Schritt 6 |
| `kubectl top node` sagt „Metrics API not available" | `kubectl -n kube-system logs deploy/metrics-server` |
| Dashboard nicht erreichbar, Pod läuft | Löst der Hostname auf die Adresse von `ingress-internal` auf? Ein Wildcard-Eintrag auf den Unraid-Host zieht sonst vor. Der NodePort `30080` ist weg |
| Dashboard zeigt überall „Forbidden" | Token abgelaufen oder von der falschen Identität. Neu: `kubectl -n headlamp create token headlamp --duration=8h` |

## Was danach noch fehlt

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
  einmal als Variable vorhanden, obwohl Schritt 6 sie beschreibt.
- **Flux synct `refs/heads/kubernetes-try`**, nicht `master`. Vor dem
  Scharfschalten drehen.

Der Rest steht unter „Nächste Schritte" im
[Sicherheitskonzept](homelab-sicherheitskonzept.html).

Und zum State: Er enthält die Cluster-PKI — wer ihn hat, hat den Cluster. Er
liegt verschlüsselt in der Gitea-Package-Registry (`tools/tf` setzt
`TF_ENCRYPTION`, `enforced` ohne Ausnahme). Die Passphrase steht in
`~/.config/homelab/tofu.env` und **nur dort**: Sie gehört so gesichert, dass
sie einen Verlust der Arbeitsstation überlebt, sonst ist der State
unbrauchbar.
