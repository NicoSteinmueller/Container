# Inbetriebnahme auf Unraid

Der Weg von einem leeren Unraid-Host zu Immich und Nextcloud im Internet.
Reihenfolge einhalten — die Portfreigabe kommt **zuletzt**, nicht zuerst.

Ausführlich steht alles in [../vm/edge/README.md](../vm/edge/README.md),
[../vm/talos/README.md](../vm/talos/README.md) und
[flux/README.md](flux/README.md); das hier ist der Ablauf.

Was bewusst *nicht* Teil der Inbetriebnahme ist, sondern später kommt, steht in
[AUSBAUSTUFEN.md](AUSBAUSTUFEN.md).

> **Stand: dieses Dokument beschreibt mehr, als es derzeit gibt.**
>
> Die Schritte 0 bis 3 lassen sich heute abarbeiten: Unraid-Host, Edge-VM,
> Talos-Node, Flux. Storage und der **interne** Ingress sind seither
> zurückgekommen, als Flux-Manifest statt als Terraform-Modul. Ab Schritt 4
> setzt der Ablauf den Rest des Plattform-Stacks voraus — interne CA,
> ingress-public, Kyverno, CrowdSec im Cluster. Der lag im Modul
> `k8s/platform`, ist entfernt worden und soll ebenso wiederkommen.
>
> Die betroffenen Schritte bleiben trotzdem hier stehen. Sie beschreiben, was
> der Wiederaufbau zu leisten hat, und die Begründungen darin sind mit dem Code
> nicht ungültig geworden. Was genau fehlt, steht am Ende von Schritt 3.

## 0. Voraussetzungen auf dem Unraid-Host

| Punkt | Prüfen mit |
|---|---|
| VM-Manager aktiv (Settings → VM Manager → Enable VMs: Yes) | `ssh root@unraid virsh list --all` |
| Anbindung ans LAN: Bridge `br0` **oder** macvtap auf `bond0`/`ethX` | `ssh root@unraid ip -br link` |
| Share `domains` vorhanden, ~120 GB frei | `ssh root@unraid df -h /mnt/cache/domains` |
| RAM-Budget, siehe unten — Container zählen mit | `ssh root@unraid free -m` |

**Zum RAM-Budget.** Die Zahl im Konzept — 1,5 GB Edge, 10 GB Talos — beschreibt
den Endausbau, nicht den Tag der Inbetriebnahme. An dem laufen Nextcloud, Immich
und Paperless noch als Container auf dem Host und belegen ihren Speicher weiter:

```
16 GB gesamt  −  ~7,5 GB Docker  −  1,5 GB Edge  =  ~5 GB frei
```

**Diese Rechnung ist eine Obergrenze, kein Budget.** Sie unterstellt, dass der
gesamte Rest der VM zusteht — der Host braucht davon aber selbst Page-Cache,
und Unraid hat ab Werk **keinen Swap**. Gemessen mit einer 4-GB-VM: 629 MB
frei, `kswapd0` dauerhaft aktiv, Page-Cache wird laufend verworfen. Darunter
der Kernel-Modul-Squashfs `/boot/bzmodules`, dessen Backing-Store der
USB-Boot-Stick ist. Der stand bei 74 % Auslastung, der ganze Host bei 70 %
iowait und 6 % User-CPU — Load 15,7, ohne dass irgendetwas gerechnet hätte.

Real verfügbar sind eher 2–2,5 GB. Ein Versuch mit 3 GB scheiterte dann aber an
der anderen Seite der Rechnung: Der Plattform-Stack ist nicht „fast nichts".
Gemessen im damals laufenden Cluster, ohne jede Nutzlast, sind es **1900 MiB
Memory-Requests** — auf einem Node, dem Talos von 3072 MiB VM nur 2880 MiB
meldet, und der davon selbst rund 600 MiB für kubelet und containerd braucht.
Talos' `runtime.OOMController` schoss daraufhin reihenweise Cgroups ab.

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
ist ab Werk leer. `vm/edge` legt deshalb selbst einen Verzeichnis-Pool an, der
auf den Share `domains` zeigt (`manage_pool`, `pool_path`); von Hand ist dafür
nichts zu tun.

Was dort liegt, sind gewöhnliche qcow2-Dateien — sichtbar in der
Unraid-Oberfläche und für die Backup-Plugins:

```
/mnt/cache/domains/edge1.qcow2
/mnt/cache/domains/homelab-cp1.qcow2
/mnt/cache/domains/debian-13-genericcloud-amd64-<snapshot>.qcow2
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

Unraid bringt stattdessen sein eigenes OVMF mit. In **beiden** tfvars-Dateien
deshalb setzen:

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

Dann statt `lan_bridge` in **beiden** Modulen setzen:

```hcl
lan_macvtap_dev = "bond0"     # ip -br link auf dem Host zeigt den Namen
```

Was das bedeutet, und das ist kein Detail: Mit macvtap erreichen sich VM und
Hypervisor-Host **nicht**. Für die Edge-VM passt das zum Konzept („kein LAN,
keine Shares, keine Unraid-Oberfläche") und ist eher ein Gewinn. Zwei Folgen
muss man aber kennen:

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

**Auf der Arbeitsstation:** `terraform`, `talosctl`, `kubectl`, `helm`.

`talosctl` muss zur gepinnten `talos_version` passen:

```bash
curl -sSL -o /usr/local/bin/talosctl \
  https://github.com/siderolabs/talos/releases/download/v1.13.7/talosctl-linux-amd64
chmod +x /usr/local/bin/talosctl
```

**Adressen festlegen** (Beispiel, muss zum eigenen Netz passen):

| Was | Adresse | Wo eingetragen |
|---|---|---|
| Unraid | 192.168.178.3 | — |
| Interner Resolver (AdGuard) | eigene LAN-Adresse des Containers, **nicht** die des Hosts | `dns_servers` in beiden Modulen |
| Edge-VM, LAN | 192.168.178.221 | `lan_ip`, Ziel der Fritzbox-Freigabe |
| Talos-Node, LAN | 192.168.178.222 | `lan_ip` in vm/talos |
| Edge-VM, DMZ | 10.10.20.2 | `edge_dmz_ip` |
| Talos-Node, DMZ | 10.10.20.3 | `node_dmz_ip` / `cluster_ingress_ip` |

Beide LAN-Adressen müssen **außerhalb** des Fritzbox-DHCP-Bereichs liegen.

## 1. Edge-VM

```bash
cd vm/edge
cp terraform.tfvars.example terraform.tfvars
```

In `terraform.tfvars` mindestens setzen:

```hcl
# Die wichtigste Zeile: ohne sie baut Terraform alles auf der eigenen
# Arbeitsstation statt auf Unraid.
libvirt_uri         = "qemu+ssh://root@192.168.178.3/system"
lan_bridge          = "br0"
lan_ip              = "192.168.178.221"
lan_gateway         = "192.168.178.1"
dns_servers         = ["192.168.178.2"]
ssh_authorized_keys = ["ssh-ed25519 AAAA... nico"]
admin_sources       = ["192.168.178.0/24"]

domain = "domain.de"
public_services = [
  { name = "immich", subdomain = "immich", strict_paths = ["/api/auth"] },
  { name = "cloud",  subdomain = "cloud",  strict_paths = ["/login"], relaxed_paths = ["/remote.php"] },
]
acme_email = "post@domain.de"
# Für die ersten Läufe:
acme_ca_server = "https://acme-staging-v02.api.letsencrypt.org/directory"
```

```bash
terraform init && terraform apply
ssh edge@192.168.178.221 cloud-init status --wait     # dauert ein paar Minuten
verify/assert-ruleset.sh
verify/egress-test.sh
```

Damit steht die VM, das isolierte Netz `edge-dmz` existiert auf dem Host —
und noch kommt niemand von außen hinein.

## 2. Talos-Node

```bash
cd ../talos
cp terraform.tfvars.example terraform.tfvars
```

Anpassen — dieselben Werte wie in Schritt 1, sonst finden sich die beiden VMs
nicht:

```hcl
libvirt_uri     = "qemu+ssh://root@192.168.178.3/system"
lan_macvtap_dev = "bond0"          # oder lan_bridge, je nach Host
lan_ip          = "192.168.178.222"
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
kubectl get nodes -o wide               # Ready, INTERNAL-IP 192.168.178.222
verify/assert-cluster.sh
```

**Wenn `talos_machine_configuration_apply` minutenlang „Still creating…" meldet**
und die VM auf Unraid trotzdem als gestartet erscheint, ist der Node im
Maintenance-Mode nicht unter `lan_ip` erreichbar. Nachsehen:

```bash
ping -c2 192.168.178.222                    # keine Antwort?
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

## 3. Cluster ausstatten

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

**Zurück sind:** Storage (`local-path.yaml`, `nfs-storage.yaml`) und der
interne Ingress mit Namespaces, NetworkPolicies und der IngressClass
`internal` (`ingress-internal.yaml`). Damit sind zwei der früheren Sperren weg:
PVCs binden, und Dienste hängen unter Hostnamen statt an NodePorts.

**Noch offen, und was daran hängt:**

- **Kein Client-Zertifikat für die Edge-VM.** Die Server-Zertifikate kommen
  von Let's Encrypt (Wildcard, DNS-01 über IONOS), damit ist der Browserpfad
  erledigt. Let's Encrypt stellt aber nur `serverAuth` aus — die Zusage „hier
  wird geprüft, DASS das Paket von der Edge kommt" braucht ein
  Client-Zertifikat. Schritt 4 hängt daran, und die Antwort dort ist offen:
  eine winzige CA nur für diese beiden Maschinen, oder WireGuard statt mTLS.
- **Kein `ingress-public`.** Die Edge-VM hat damit weiterhin keine
  Gegenstelle; eine Portfreigabe führte ins Leere. Beim Bau dieses zweiten
  Controllers muss `ingress-internal` auf `hostNetwork` zurück, samt Sysctl auf
  dem Node — die Begründung steht in
  [flux/clusters/talos-cp1/ingress-internal.yaml](flux/clusters/talos-cp1/ingress-internal.yaml).
- **Kein Kyverno.** Die Regel auf `ingressClassName: public` gibt es damit
  nicht. Solange die Klasse `public` gar nicht existiert, fehlt ihr auch der
  Anwendungsfall. Die Reloader-Annotation, die Kyverno ebenfalls setzte, wird
  nicht mehr gebraucht — Reloader regelt das seit dem Wegfall selbst (siehe
  [flux/README.md](flux/README.md), Abschnitt Rotation).
- **Kein CSR-Genehmiger.** `kubelet_server_certs` in `vm/talos` muss aus
  bleiben, sonst bricht der Apply dort ab.

## 4. Die drei Bootstrap-Schritte

> **Setzt den Plattform-Stack voraus, siehe Ende von Schritt 3.** Alles hier — step-ca im
> Cluster, die Skripte unter `k8s/platform/scripts/` — ist mit dem Modul
> entfernt worden. Der Ablauf steht als Vorgabe für den Wiederaufbau.

Zugangsdaten kommen bewusst nicht aus Terraform. Der Reihe nach:

```bash
# a) Interne CA in vm/edge eintragen
kubectl -n step-ca exec sts/step-ca -- \
  step certificate fingerprint /home/step/certs/root_ca.crt
```

In `vm/edge/terraform.tfvars`:

```hcl
step_ca_url         = "https://10.10.20.3:9000"
step_ca_fingerprint = "<Ausgabe von oben>"
cluster_ingress_ip  = "10.10.20.3"
```

```bash
cd ../../vm/edge && terraform apply

# b) Client-Zertifikat der Edge (Token läuft nach Minuten ab)
../../k8s/platform/scripts/edge-token.sh edge1.dmz
ssh edge@192.168.178.221 sudo edge-mtls-bootstrap '<token>'

# c) CrowdSec-Zugangsdaten
../../k8s/platform/scripts/edge-register.sh
# das Skript gibt den fertigen edge-crowdsec-connect-Aufruf für die VM aus
```

Danach in `vm/edge/terraform.tfvars` `crowdsec_bouncer_armed = true` setzen
und `terraform apply`. Der **Firewall**-Bouncer bleibt noch aus.

## 5. Erst jetzt: DNS und Fritzbox

> **Setzt den Plattform-Stack voraus, siehe Ende von Schritt 3.** Die Edge-VM allein steht zwar,
> aber hinter ihr wartet kein `ingress-public` — eine Portfreigabe führt
> derzeit ins Leere. Punkt 5 der Liste (interne Namen im Heimnetz) ist davon
> unabhängig und gilt schon heute.

1. `immich.domain.de` und `cloud.domain.de` per DynDNS auf die eigene IP —
   über den DNS-Anbieter, nicht über MyFRITZ!.
2. ACME-DNS-Instanz aufsetzen, ihre Adresse als `acme_dns_api_base` in
   `vm/edge/terraform.tfvars` eintragen und anwenden — ohne diesen Wert legt
   Traefik den Resolver `acmedns` gar nicht erst an. Danach
   `_acme-challenge`-CNAMEs anlegen (`terraform output acme_challenge_cnames`
   in `vm/edge`; das Ziel steht nach dem ersten Lauf in
   `/var/lib/traefik/acme-dns.json` auf der VM), Zertifikate erst gegen
   Staging holen, dann `acme_ca_server` auf Produktion umstellen.
3. Fritzbox: **nur 443/TCP** auf `192.168.178.221`. Port 80 bleibt zu.
4. **IPv6 getrennt prüfen** — „Host komplett freigeben" öffnet mehr als
   gedacht. UPnP aus, MyFRITZ!-Fernzugriff aus.
5. Interne Namen **nur im Heimnetz** auflösen (AdGuard oder Fritzbox), nicht
   per DynDNS: `dashboard.<interne-domain>` und `whoami.<interne-domain>` auf
   die LAN-Adresse des Nodes. Im öffentlichen DNS haben sie nichts verloren.
   Gibt es dort schon einen Wildcard-Eintrag auf den Unraid-Host, müssen diese
   Namen explizit gesetzt werden — sonst landen sie beim Traefik im
   Docker-Netz des Hosts.

```bash
vm/edge/verify/proxy-test.sh cloud.domain.de
```

Die beiden wichtigsten Proben darin: Ein gefälschter `X-Forwarded-For` darf im
Log **nicht** auftauchen, und ein fremder Hostname muss im TLS-Handshake enden.

## 6. Dashboard und Metriken

Das Dashboard steht mit Schritt 3 schon und hängt seit `ingress-internal.yaml`
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
als HelmRelease aus Schritt 3:

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
> `Pending`, und kein Dienst mit Daten kommt hoch — siehe Ende von Schritt 3.
> Der Abschnitt zum RAM weiter unten gilt unabhängig davon.

Namespaces, NetworkPolicies und die Klasse `internal` stehen wieder; ein
Ingress braucht nur noch die richtige Klasse:

```yaml
spec:
  ingressClassName: internal   # paperless          -> nur aus dem LAN
  # ingressClassName: public   # nextcloud, immich  -> aus dem Internet
```

`public` ist dabei noch keine Option: Die Klasse existiert nicht, solange
`ingress-public` fehlt. Und zwei Handgriffe kommen je Dienst dazu, die es
früher nicht gab — beide wegen `rbac.namespaced` am Controller:

- der neue Namespace muss an drei Stellen in
  [flux/clusters/talos-cp1/ingress-internal.yaml](flux/clusters/talos-cp1/ingress-internal.yaml)
  stehen: `providers.kubernetesIngress.namespaces`,
  `providers.kubernetesCRD.namespaces` und eine RoleBinding auf die ClusterRole
  `traefik-internal-namespaced`,
- und er braucht eine NetworkPolicy, die `traefik-internal` hereinlässt —
  sonst greift sein eigenes Default-Deny.

`public` in einem internen Namespace lehnte früher Kyverno ab; die Regel kommt
mit ihm zurück.

**Pro migriertem Dienst, in dieser Reihenfolge:**

```bash
# 1. Im Cluster hochziehen, Daten übernehmen, über ingress-internal prüfen
# 2. Erst dann den Container auf dem Host stoppen - jetzt ist der RAM frei
ssh root@unraid docker stop nextcloud nextcloud_postgres nextcloud_redis

# 3. RAM der VM nachziehen
cd vm/talos && vim terraform.tfvars     # vm_memory_mib erhöhen
terraform apply                         # in-place, kein Neubau

# 4. Wirksam beim nächsten Start
talosctl -n 192.168.178.222 shutdown
ssh root@unraid virsh start homelab-cp1
```

Schritt 2 vor Schritt 3, nicht umgekehrt: Sonst konkurrieren Container und VM
um denselben Speicher, und auf einem Host ohne Swap holt sich der OOM-Killer
den größten Prozess — das ist qemu, also der ganze Cluster.

Den Container erst löschen, wenn der Dienst im Cluster ein paar Tage steht.
Bis dahin ist er der Rückweg.

## 8. Scharfschalten (nach 1-2 Wochen)

> **Setzt den Plattform-Stack voraus, siehe Ende von Schritt 3.** CrowdSec läuft heute weder im
> Cluster noch als Gegenstelle der Edge.

```bash
kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli alerts list
ssh edge@192.168.178.221 sudo edge-crowdsec-connect --arm-firewall-bouncer
```

Danach in `vm/edge/terraform.tfvars` den Egress zumachen: Counter lesen
(`sudo nft list table inet edge`), `egress_targets` füllen,
`egress_open = false`, `terraform apply`, `verify/egress-test.sh`.

## Wenn etwas klemmt

| Symptom | Erste Stelle |
|---|---|
| `terraform apply` kommt nicht an libvirt | `virsh -c qemu+ssh://root@unraid/system list` von Hand |
| `Failed to open file '…edk2-i386-vars.fd'` | `efi_loader`/`efi_vars_template` setzen, siehe Abschnitt 0 |
| `AppArmor-Profil … kann nicht geladen werden` | Der Apply läuft gegen den **lokalen** libvirt — `libvirt_uri` in der tfvars fehlt. `terraform destroy`, URI setzen, erneut anwenden |
| `Cannot get interface MTU on 'br0'` | Kein Bridging auf dem Host — `lan_macvtap_dev = "bond0"` statt `lan_bridge` |
| Edge-VM ohne Netz | `virsh console edge1`, MACs und `lan_bridge`/`lan_macvtap_dev` prüfen |
| `talos_machine_configuration_apply` hängt, VM läuft aber | Node hat im Maintenance-Mode eine DHCP-Adresse statt `lan_ip` — siehe Schritt 2 |
| `data.talos_cluster_health` läuft in den Timeout, `talosctl` antwortet aber | Control Plane startet nicht. `talosctl -n … containers -k` zeigt `CONTAINER_EXITED`, die Begründung steht in `talosctl -n … logs -k kube-system/kube-apiserver-<node>:kube-apiserver` |
| Static Pod neu gerendert, aber kein neuer Startversuch | Kubelet hängt: `talosctl -n … service kubelet restart` |
| Talos bleibt NotReady | `kubectl -n kube-system get pods -l k8s-app=cilium`, `talosctl -n … dmesg` |
| Dienst über NodePort im Timeout, Service und Endpoint sehen gesund aus | Fast immer eine NetworkPolicy, oft eine vom Chart mitgebrachte — mit Cilium werden sie erstmals durchgesetzt, unter Flannel waren sie wirkungslos. `kubectl -n kube-system exec ds/cilium -- hubble observe --last 200 --type drop`; Quelle `(world)` heißt: Regel ohne `ipBlock` erfasst LAN-Clients nicht |
| Node nicht mehr erreichbar | `admin_sources` falsch → serielle Konsole, siehe vm/talos/README.md |
| Edge erreicht den Cluster nicht | `vm/edge/verify/egress-test.sh`, dann `talosctl -n … get nftableschains` |
| ACME schlägt fehl | Zeit (NTP), CNAME-Delegation, Staging-Verzeichnis verwenden |
| `HelmRelease` oder `Kustomization` bleibt auf `False` | `kubectl -n flux-system describe helmrelease <name>`; bei `homelab-secrets` fast immer die drei Bootstrap-Secrets, siehe [flux/README.md](flux/README.md) |
| Secret im Cluster enthält wörtlich `ENC[AES256_GCM,…]` | Der `decryption`-Block der Kustomization greift nicht — der age-Schlüssel in `sops-age` passt nicht zu `.sops.yaml` |
| PVC bleibt `Pending` | Es gibt keine StorageClass, siehe Ende von Schritt 3. `kubectl get storageclass` ist leer |
| Ingress antwortet nicht | `kubectl -n traefik-internal logs deploy/traefik-internal`. Kommt dort nichts an, ist es fast immer die NetworkPolicy: `kubectl -n kube-system exec ds/cilium -- hubble observe --last 200 --type drop`. Notbremse: `kubectl -n traefik-internal delete networkpolicy allow-from-lan` |
| Ingress wird gar nicht bedient, Objekt sieht richtig aus, Traefik antwortet mit 404 | Zwei Kandidaten: Sein Namespace fehlt in `providers.kubernetesIngress.namespaces` oder hat keine RoleBinding. Oder — falls jemand `rbac.namespaced: true` gesetzt hat — greift `spec.ingressClassName` gar nicht mehr, siehe Abschnitt „RBAC von Hand" in [flux/clusters/talos-cp1/README.md](flux/clusters/talos-cp1/README.md) |
| `RoleBinding ... cannot change roleRef` beim Apply | Eine gleichnamige Bindung zeigt noch auf eine `Role` statt auf die `ClusterRole`. `roleRef` ist unveränderlich — alte löschen oder unter eigenem Namen anlegen |
| Traefik in CrashLoop mit `bind: permission denied` | Es läuft mit `hostNetwork` statt `hostPort` — dann braucht der Node den Sysctl `net.ipv4.ip_unprivileged_port_start=0`. Siehe Kopf von `ingress-internal.yaml` |
| Browser warnt vor dem Zertifikat | Steht `caServer` noch auf dem Staging-Verzeichnis? Dessen Wurzel kennt kein Browser. Sonst: `kubectl -n traefik-internal logs deploy/traefik-internal \| grep -i acme` |
| ACME schlägt fehl mit DNS-Fehlern | IONOS-API-Key prüfen (`traefik-ionos` in homelab-secrets, Format `<prefix>.<secret>`). Vorsicht mit Wiederholungen: fünf Fehlversuche je Stunde, dann sperrt Let's Encrypt |
| Alles tot nach Policy-Änderung *(ingress-public, sobald es steht)* | `kubectl -n traefik-public delete networkpolicy allow-from-edge` |
| `kubectl logs`/`exec` brechen weg, Node ist aber Ready | Kubelet-CSR ungenehmigt. `kubectl get csr`, dann `kubectl -n kube-system logs -l app.kubernetes.io/name=kubelet-csr-approver`. Notbremse: `kubelet_server_certs = false` in `vm/talos`, apply, reboot |
| `apply` in `vm/talos` bricht ab mit „kubelet server certificate rotation is enabled, but CSR is not approved" | `kubelet_server_certs` wurde gesetzt, ohne dass ein CSR-Genehmiger im Cluster läuft — den gibt es derzeit nicht, siehe Schritt 6 |
| `kubectl top node` sagt „Metrics API not available" | `kubectl -n kube-system logs deploy/metrics-server` |
| Dashboard nicht erreichbar, Pod läuft | Löst der Hostname auf die LAN-Adresse des Nodes auf? Ein Wildcard-Eintrag auf den Unraid-Host zieht sonst vor. Der NodePort `30080` ist weg |
| Dashboard zeigt überall „Forbidden" | Token abgelaufen oder von der falschen Identität. Neu: `kubectl -n headlamp create token headlamp --duration=8h` |

## Was danach noch fehlt

Vom Plattform-Stack fehlen noch `ingress-public` als Gegenstelle der Edge-VM,
Kyverno und CrowdSec — diesmal als Flux-Manifest statt als Terraform-Modul.
Storage, der interne Ingress und dessen Zertifikate sind zurück; eine interne
CA braucht es dafür nicht mehr, seit die Zertifikate von Let's Encrypt kommen.

Danach unverändert offen: kein Backup, keine NFS-Exporte vom Array, kein
Monitoring — „Nächste Schritte" im
[Sicherheitskonzept](homelab-sicherheitskonzept.html).

Und zum State: Er enthält die Cluster-PKI — wer ihn hat, hat den Cluster. Er
liegt verschlüsselt in der Gitea-Package-Registry (`tools/tf` setzt
`TF_ENCRYPTION`, `enforced` ohne Ausnahme). Die Passphrase steht in
`~/.config/homelab/tofu.env` und **nur dort**: Sie gehört so gesichert, dass
sie einen Verlust der Arbeitsstation überlebt, sonst ist der State
unbrauchbar.
