# Inbetriebnahme auf Unraid

Der Weg von einem leeren Unraid-Host zu Immich und Nextcloud im Internet.
Reihenfolge einhalten — die Portfreigabe kommt **zuletzt**, nicht zuerst.

Ausführlich steht alles in [../vm/edge/README.md](../vm/edge/README.md),
[../vm/talos/README.md](../vm/talos/README.md) und
[platform/README.md](platform/README.md); das hier ist der Ablauf.

## 0. Voraussetzungen auf dem Unraid-Host

| Punkt | Prüfen mit |
|---|---|
| VM-Manager aktiv (Settings → VM Manager → Enable VMs: Yes) | `ssh root@unraid virsh list --all` |
| Anbindung ans LAN: Bridge `br0` **oder** macvtap auf `bond0`/`ethX` | `ssh root@unraid ip -br link` |
| Share `domains` vorhanden, ~120 GB frei | `ssh root@unraid df -h /mnt/user/domains` |
| RAM-Budget, siehe unten — Container zählen mit | `ssh root@unraid free -m` |

**Zum RAM-Budget.** Die Zahl im Konzept — 1,5 GB Edge, 10 GB Talos — beschreibt
den Endausbau, nicht den Tag der Inbetriebnahme. An dem laufen Nextcloud, Immich
und Paperless noch als Container auf dem Host und belegen ihren Speicher weiter:

```
16 GB gesamt  −  ~7,5 GB Docker  −  1,5 GB Edge  =  ~5 GB frei
```

Die Talos-VM startet deshalb mit **4 GB** und wächst erst mit den migrierten
Diensten. Der Ablauf pro Dienst — Container stoppen, *dann* `vm_memory_mib`
erhöhen, VM neu starten — steht in [../vm/talos/README.md](../vm/talos/README.md).
`memory` ist kein ForceNew-Feld; die VM wird dabei nicht neu gebaut.

Vor dem Start einmal gegenprüfen, was der Host wirklich frei hat:

```bash
ssh root@unraid free -m
ssh root@unraid 'docker stats --no-stream --format "{{.Name}}\t{{.MemUsage}}"' | sort -k2 -h
```

**Zum Ablageort der VM-Disks.** Unraid definiert keine libvirt-Storage-Pools —
es schreibt VM-Disks über absolute Pfade ins Domain-XML, `virsh pool-list --all`
ist ab Werk leer. `vm/edge` legt deshalb selbst einen Verzeichnis-Pool an, der
auf den Share `domains` zeigt (`manage_pool`, `pool_path`); von Hand ist dafür
nichts zu tun.

Was dort liegt, sind gewöhnliche qcow2-Dateien — sichtbar in der
Unraid-Oberfläche und für die Backup-Plugins:

```
/mnt/user/domains/edge1.qcow2
/mnt/user/domains/homelab-cp1.qcow2
/mnt/user/domains/debian-13-genericcloud-amd64-<snapshot>.qcow2
```

Liegt der Share wie üblich auf einem Cache-Pool (`shareUseCache="only"` in
`/boot/config/shares/domains.cfg`), lohnt `pool_path = "/mnt/cache/domains"`:
derselbe Ort, aber ohne die shfs-FUSE-Schicht dazwischen — bei VM-Disks ist
das spürbar.

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
  Für den jetzigen Stand (PVCs über local-path) egal; sobald die Nutzerdaten
  auf das Array wandern, ist es der Punkt, an dem entweder Bridging
  eingeschaltet oder ein zweites Bein ergänzt werden muss.

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

vm_memory_mib = 4096               # Startwert, siehe RAM-Budget oben
```

```bash
terraform init && terraform apply       # 5-10 Minuten, wartet auf einen gesunden Cluster
export TALOSCONFIG=$PWD/talosconfig KUBECONFIG=$PWD/kubeconfig
kubectl get nodes -o wide               # Ready, INTERNAL-IP 192.168.178.222
verify/assert-cluster.sh
```

Wenn der Apply hängt: `virsh -c qemu+ssh://root@192.168.178.3/system console homelab-cp1`.

## 3. Cluster ausstatten

```bash
cd ../../k8s/platform
cp terraform.tfvars.example terraform.tfvars    # dieselben Adressen eintragen
terraform init && terraform apply
```

Beim allerersten Lauf kann der Bootstrap-Job der CA noch nicht durch sein —
dann schlicht ein zweites Mal `terraform apply`.

```bash
verify/assert-platform.sh
terraform output bootstrap_schritte
```

## 4. Die drei Bootstrap-Schritte

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

```bash
vm/edge/verify/proxy-test.sh cloud.domain.de
```

Die beiden wichtigsten Proben darin: Ein gefälschter `X-Forwarded-For` darf im
Log **nicht** auftauchen, und ein fremder Hostname muss im TLS-Handshake enden.

## 6. Anwendungen

Namespaces, NetworkPolicies und IngressClasses stehen schon. Ein Ingress
braucht nur noch die richtige Klasse:

```yaml
spec:
  ingressClassName: public     # nextcloud, immich  -> aus dem Internet
  # ingressClassName: internal # paperless          -> nur aus dem LAN
```

`public` in einem internen Namespace lehnt Kyverno ab — das ist Absicht und
getestet.

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

## 7. Scharfschalten (nach 1-2 Wochen)

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
| Talos bleibt NotReady | `kubectl -n kube-system get pods -l k8s-app=cilium`, `talosctl -n … dmesg` |
| Node nicht mehr erreichbar | `admin_sources` falsch → serielle Konsole, siehe vm/talos/README.md |
| Edge erreicht den Cluster nicht | `vm/edge/verify/egress-test.sh`, dann `talosctl -n … get nftableschains` |
| ACME schlägt fehl | Zeit (NTP), CNAME-Delegation, Staging-Verzeichnis verwenden |
| Ingress antwortet nicht | `kubectl -n traefik-public logs deploy/traefik-public`; fehlt das Secret `ingress-public-tls`, dann `kubectl -n step-ca logs job/ingress-cert-bootstrap` |
| Alles tot nach Policy-Änderung | `kubectl -n traefik-public delete networkpolicy allow-from-edge` |

## Was danach noch fehlt

Kein Backup, keine NFS-Exporte vom Array, kein Monitoring — siehe „Was noch
offen ist" in [platform/README.md](platform/README.md) und „Nächste Schritte"
im [Sicherheitskonzept](homelab-sicherheitskonzept.html).

Und: Die drei `terraform.tfstate`-Dateien enthalten die Cluster-PKI. Sie
liegen nur auf der Arbeitsstation und gehören verschlüsselt gesichert — wer
sie hat, hat den Cluster.
