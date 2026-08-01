# Firewall-VM

Alpine Linux mit nftables als Segmentierungspunkt zwischen Fritzbox, DMZ und
Cluster-Netz – Schritt 3 aus
[../../k8s/Edge-Architektur.md](../../k8s/Edge-Architektur.md), Abschnitt 9.

Ein `terraform apply` erzeugt Netze, VM, Regelsatz und Härtung vollständig.
Danach ist auf der VM nichts mehr von Hand einzurichten.

## Was hier entsteht

| Ressource | Wert |
|---|---|
| libvirt-Netz `fw-mgmt` | isoliert, `10.10.10.0/24`, Bridge `virbr-fwmgmt`, Host auf `.1` |
| libvirt-Netz `fw-dmz` | isoliert, **ohne IP und ohne DHCP**, Bridge `virbr-dmz` |
| libvirt-Netz `fw-cluster` | isoliert, **ohne IP und ohne DHCP**, Bridge `virbr-cluster` |
| VM `fw1` | 1 vCPU, 512 MB RAM, 4 GB Disk, Alpine 3.24.1 (UEFI-Cloud-Image) |
| WAN | `192.168.178.6` auf der Host-Bridge `br0` |
| DMZ | Firewall `10.10.20.1`, Edge-VM `10.10.20.10` |
| Cluster | Firewall `10.10.30.1`, Ingress-LB `10.10.30.100` |
| Management | Firewall `10.10.10.2`, **einziger SSH-Zugang** |

```
Internet ──▶ Fritzbox ──443──▶  192.168.178.6  (br0)
                                      │
                              ┌───────┴────────┐
                              │  fw1  nftables │──── 10.10.10.2  Management (nur Host)
                              └──┬──────────┬──┘
                     10.10.20.1  │          │  10.10.30.1
                            DMZ  ▼          ▼  Cluster
                        Edge-VM .10   Talos-Nodes / Ingress .100
```

## Voraussetzungen

- `terraform`, `libvirt`/`qemu-kvm`, Benutzer in der Gruppe `libvirt`
- OVMF/UEFI-Firmware auf dem Host (`edk2-ovmf` bzw. `ovmf`)
- Eine vorhandene Host-Bridge ins Heimnetz. Auf Unraid heißt sie in der Regel
  `br0`; vorher gegenprüfen:

  ```bash
  ip -br link
  ```

- `192.168.178.6` darf im Heimnetz nicht anderweitig vergeben sein. Entweder in
  der Fritzbox reservieren oder außerhalb des DHCP-Bereichs wählen.

## Aufbauen

```bash
cd vm/firewall
cp terraform.tfvars.example terraform.tfvars   # ssh_authorized_keys eintragen
terraform init
terraform apply
```

`terraform.tfvars` enthält keine Geheimnisse, folgt aber der Konvention des
Repos (`example.env` im Git, `.env` nicht) und ist deshalb ausgeschlossen.

Der erste Boot dauert ein bis zwei Minuten: Cloud-Init zieht das Dateisystem
auf, installiert die Pakete, schreibt Regelsatz und Härtung und startet den
Firewall-Service. Zusehen kann man über die serielle Konsole:

```bash
virsh -c qemu:///system console fw1
```

Danach:

```bash
ssh fwadmin@10.10.10.2      # nur vom Hypervisor-Host aus erreichbar
sudo nft -s list ruleset
```

## Verifikation – nicht optional

[Edge-Architektur](../../k8s/Edge-Architektur.md), Abschnitt 5 hält fest, dass
die Entscheidung gegen OPNsense nur trägt, wenn die Kontrolle, die ein GUI
mitliefern würde, automatisiert nachgebaut wird. Beides läuft vom
Hypervisor-Host:

```bash
# 1. Kein Drift: Datei und geladener Regelsatz entsprechen dem Repo
vm/firewall/verify/assert-ruleset.sh

# 2. Segmentierung wirkt wirklich - Test aus der DMZ heraus
sudo vm/firewall/verify/egress-test.sh
sudo vm/firewall/verify/egress-test.sh --segment cluster
```

Der Egress-Test braucht **keine** fertige Edge-VM: er hängt eine wegwerfbare
Network-Namespace an die DMZ-Bridge und misst von dort. Damit ist Schritt 4 der
Umsetzungsreihenfolge erfüllbar, bevor die erste Last darüber läuft.

Er unterscheidet außerdem zwischen `blocked` (stiller Drop – die Firewall) und
`refused` (geroutet, aber niemand lauscht). Solange Edge und Cluster noch nicht
stehen, ist `refused` bei erlaubten Zielen der erwartete Zwischenstand.

Sobald die Edge-VM läuft, dasselbe von dort:

```bash
vm/firewall/verify/egress-test.sh --ssh root@10.10.20.10
```

## Regeln ändern

Quelle der Wahrheit ist [templates/nftables.nft.tftpl](templates/nftables.nft.tftpl)
bzw. die Variablen in [variables.tf](variables.tf). Eine Änderung ist ein PR mit
lesbarem Diff – genau der Punkt, an dem Git das OPNsense-UI schlägt.

```bash
terraform apply                      # rendert neu, Cloud-Init-ISO bekommt neuen Hash
vm/firewall/scripts/push-ruleset.sh  # lädt den Regelsatz ohne Reboot
```

`terraform apply` allein reicht nicht: Cloud-Init wendet seine Module nur bei
neuer `instance-id` an, also erst nach einem Reboot. `push-ruleset.sh` prüft
erst die Syntax auf der VM, installiert dann und lässt zum Schluss
`assert-ruleset.sh` laufen.

Für Änderungen an Paketen, sshd oder sysctl hilft nur der Reboot – die neue
`instance-id` sorgt dann dafür, dass Cloud-Init alles erneut anwendet:

```bash
terraform apply && virsh -c qemu:///system reboot fw1
```

## Fritzbox

Der Aufbau ist genau so gebaut, dass die Fritzbox nichts können muss, was sie
nicht kann ([Edge-Architektur](../../k8s/Edge-Architektur.md), Abschnitt 5):

1. **Heimnetz → Netzwerk → Netzwerkverbindungen** → `fw1` → *„Diesem
   Netzwerkgerät immer die gleiche IPv4-Adresse zuweisen"*
2. **Internet → Freigaben → Portfreigaben** → 443 **TCP und UDP** auf
   `192.168.178.6` (UDP für HTTP/3)
3. **Internet → Freigaben → IPv6** → Firewall aktiv, **keine** Freigaben
4. **Kein** „Exposed Host"

Eine statische Route für `10.10.20.0/24` braucht es **nicht**: Split-DNS in
AdGuard zeigt für die öffentlichen Namen auf `192.168.178.6`, und die
DNAT-Regel schickt LAN-Clients denselben Weg wie Internet-Clients. Ein
Durchsetzungspunkt statt zwei.

## Was die Regeln tun

| Von | Nach | Erlaubt |
|---|---|---|
| Internet/LAN | Edge-VM | 443 tcp+udp (per DNAT auf `10.10.20.10`) |
| DMZ | Cluster | 443 tcp, **nur** von der Edge-IP auf die Ingress-LB-IP |
| DMZ | Internet | 53, 80, 443 tcp / 53, 123, 443 udp |
| Cluster | Internet | dieselben Ports (Image-Pulls, ACME, NTP) |
| DMZ, Cluster | Heimnetz, Management | **nichts** – mit Logging |
| Cluster | DMZ | nur als Antwort auf bestehende Verbindungen |
| Management | Firewall | SSH |

Vor allem anderen steht in `input` und `forward` je ein Anti-Spoofing-Block:
jedes Bein nimmt nur Absender aus dem eigenen Segment an, und über WAN kommt
kein Paket herein, das sich als DMZ, Cluster oder Management ausgibt. Das
dupliziert `rp_filter` bewusst – ein Gast in der DMZ, der `10.10.10.x` als
Absender setzt, würde sonst nur von einem sysctl außerhalb dieses Regelsatzes
aufgehalten, und genau darauf bauen sowohl die SSH-Regel als auch der
Panic-Regelsatz, die Management nur an der Quelladresse erkennen.

Zwei Eigenheiten, die man kennen sollte:

**WAN und LAN teilen sich ein Interface.** Die Firewall steht mit einem Bein im
Heimnetz – „DMZ → LAN DENY" lässt sich deshalb nicht über `oifname` ausdrücken.
Der Egress ist stattdessen auf Ziele **außerhalb** aller privaten Netze
begrenzt (`ip daddr != @private_nets`), und die Deny-Regel steht zusätzlich
explizit davor, damit Treffer im Log auftauchen.

**Interface-Namen kommen aus den MAC-Adressen.** `fw-render-interfaces`
schreibt beim Start `/etc/nftables.d/interfaces.nft`, das der Regelsatz
einbindet. Damit hängt die Zuordnung der vier Segmente nicht daran, in welcher
Reihenfolge der Kernel `eth0..eth3` vergibt – ein vertauschtes Interface wäre
eine Firewall, die etwas anderes tut als das, was im Repo steht.

## Bewusste Entscheidungen

**Cloud-Init statt Ansible.** Das Konzept sah Ansible für den Regelsatz vor. Die
VM hat aber genau eine Aufgabe, und Ansible bräuchte einen zweiten Weg auf die
Maschine – zusätzlich zu dem SSH-Zugang, den man ohnehin so eng wie möglich
halten will. Alles kommt deshalb aus Terraform; Ansible bleibt für die
Unraid-Hosts und Minikube zuständig. Die Auditierbarkeit ändert sich nicht: der
Regelsatz steht weiterhin als Text im Repo und wird gegen den laufenden Stand
geprüft.

**Eigener Firewall-Service statt `/etc/init.d/nftables`.** Der Standard-Service
lädt Regeln und meldet im Fehlerfall einen Fehler – zurück bleibt ein Router
ganz ohne Regeln, also offen. Hier hängt `ip_forward` am erfolgreichen Laden:
klappt es nicht, greift `nftables.panic.nft` (alles zu außer SSH über
Management) und Forwarding bleibt aus. Fail-closed statt fail-open.

**Der Firewall-Service wendet die Kernel-Härtung selbst an.** `firewall` und
`sysctl` liegen beide im `boot`-Runlevel, und OpenRC startet unabhängige
Services parallel – ohne Ordnung wäre es Zufall, ob `rp_filter` schon steht,
wenn die VM zu routen beginnt, und ob `99-firewall.conf` danach `ip_forward`
wieder auf `0` zieht. Der Service hat deshalb `after sysctl` in `depend()` *und*
liest die Datei vor der Freigabe des Forwardings selbst ein. `assert-ruleset.sh`
prüft das Ergebnis mit.

Aus demselben Aufruf kommt `net.netfilter.nf_conntrack_helper = 0`. Der Schlüssel
steht nicht in `99-firewall.conf`, weil er erst existiert, sobald nftables das
Conntrack-Modul geladen hat. Er zählt trotzdem: `ct state related accept` steht
in der forward-Chain über den DENY-Regeln, und ein automatisch zugewiesener
Helper (FTP, SIP, TFTP) könnte aus DMZ oder Cluster heraus eine
RELATED-Erwartung ins Heimnetz öffnen – vorbei an der Segmentierung.

**Management-Netz ohne Verbindung zum LAN.** SSH ist ausschließlich auf
`10.10.10.2` gebunden, erreichbar nur vom Hypervisor selbst. Der Weg von der
Workstation führt also über den Host:

```bash
ssh -J root@unraid fwadmin@10.10.10.2
```

Das ist die Maßnahme, die laut Konzept den Sicherheitsunterschied zwischen
Alpine und OPNsense am stärksten einebnet – und die am häufigsten vergessen
wird.

**DMZ und Cluster ohne DHCP und ohne Host-Adresse.** Beide Netze sind reine
L2-Segmente. Der Hypervisor hat dort kein Bein, und Default-Gateway ist die
Firewall statt libvirt. Der Preis: **Gäste in diesen Segmenten müssen statisch
adressiert werden.** Für den Talos-Cluster heißt das, dass die Node-IP künftig
aus der Machine-Config kommt und nicht wie in `vm/talos-test` aus einer
DHCP-Reservierung.

**IPv6 doppelt abgeschaltet** – per sysctl und über eine `ip6`-Tabelle mit
`policy drop`. Globale v6-Adressen in DMZ oder Cluster wären an NAT und
Firewall vorbei direkt erreichbar; laut Konzept der häufigste Fehler bei genau
dieser Konstruktion.

**UEFI mit q35, Secure Boot aus.** Dieselbe Begründung wie in
[../talos-test/README.md](../talos-test/README.md): q35 hängt alle Geräte hinter
PCIe-Root-Ports, die SeaBIOS nicht enumeriert – der Gast sähe kein einziges
virtio-Gerät. Deshalb das UEFI-Cloud-Image von Alpine, und Secure Boot explizit
aus, weil libvirt sonst das OVMF mit den Microsoft-Keys wählt.

**Kein Egress-Filter für die Firewall selbst.** Die VM betreibt keinen Dienst,
der nach außen spricht, außer `apk`, `chrony` und DNS. Ein Output-Filter brächte
hier wenig und ist der häufigste Weg, sich auszusperren.

## Betrieb

```bash
sudo rc-service firewall check     # Syntax prüfen, nichts laden
sudo rc-service firewall restart   # Regelsatz neu laden
sudo rc-service firewall show      # kanonische Ausgabe (nft -s list ruleset)
sudo nft -j list counters          # Treffer pro Regel
sudo tail -f /var/log/messages     # Deny-Logs: nft-deny-to-lan, nft-drop-forward
```

Die Deny-Regeln loggen mit den Präfixen `nft-deny-to-lan`,
`nft-deny-to-mgmt`, `nft-deny-clu-dmz`, `nft-drop-forward` und
`nft-drop-input`. Mit `syslog_remote` gehen dieselben Zeilen zusätzlich an den
bestehenden Loki-Stack.

`apk upgrade` läuft wöchentlich über `crond` (`/etc/periodic/weekly/apk-upgrade`,
abschaltbar über `auto_upgrade`). Kernel-Updates werden erst nach einem Reboot
wirksam – der bleibt bewusst manuell, weil währenddessen nichts nach außen
erreichbar ist.

## Aufräumen

```bash
terraform destroy
```

Entfernt VM, Disks, Cloud-Init-ISO und die drei Netze. Solange Edge-VM oder
Talos-Nodes an `fw-dmz`/`fw-cluster` hängen, schlägt das Löschen der Netze fehl –
diese VMs vorher abbauen.

## Restrisiko außerhalb dieses Moduls

Zwei Wege führen an dem Regelsatz vorbei, weil sie ihn gar nicht erst
durchlaufen. Beide sind hier nicht zu schließen – aber sie gehören genannt,
sonst liest sich „DMZ → LAN DENY" stärker, als es ist.

**Der Hypervisor hängt selbst an den Segment-Bridges.** `fw-dmz` und
`fw-cluster` haben keine Adresse auf dem Host, das Bridge-Interface existiert
dort aber trotzdem. Linux ist standardmäßig ein *weak host*: Pakete, die auf
`virbr-dmz` ankommen und an eine ganz andere lokale Adresse des Hosts gerichtet
sind, nimmt der Kernel an. libvirt legt für isolierte Netze `FORWARD`-REJECTs
an, aber nichts für `INPUT`. Eine kompromittierte Edge-VM kann den Unraid-Host
damit direkt ansprechen, ohne die Firewall-VM zu passieren – blind, weil ohne
Rückweg, aber ausreichend für alles, was keine Antwort braucht. Auf dem
Hypervisor gegenprüfen und schließen:

```bash
# Zum Prüfen welche Netzwerke es gibt
ip -br link 2>/dev/null | grep -E 'virbr|br0' || echo "(keine virbr*/br0 Interfaces)"; echo "=== /proc/sys/net/ipv4/conf ==="; ls /proc/sys/net/ipv4/conf/ 2>/dev/null | tr '\n' ' '; echo; echo "=== libvirt-Netze ==="; virsh -c qemu:///system net-list --all 2>&1 | head -20
```

```bash
iptables -S INPUT | grep -E 'virbr-(dmz|cluster)'   # erwartet: nichts -> Lücke

# Der Interface-Name wird erst beim Paketempfang aufgelöst - die Regeln lassen
# sich also setzen, bevor `terraform apply` die Bridges überhaupt anlegt.
iptables -I INPUT -i virbr-dmz     -j DROP
iptables -I INPUT -i virbr-cluster -j DROP

# Bewusst über `all` statt per Interface: /proc/sys/net/ipv4/conf/<iface>
# entsteht erst mit dem Interface und verschwindet mit ihm wieder - ein
# `virsh net-destroy` würde die Einstellung sonst still zurücknehmen. Beim
# ARP-Reply bildet der Kernel max(all, iface), `all` wirkt deshalb sofort und
# auch auf Bridges, die libvirt erst später erzeugt.
sysctl -w net.ipv4.conf.all.arp_ignore=1
```

`arp_ignore=1` heißt „nur für Adressen antworten, die auf dem empfangenden
Interface konfiguriert sind" und gilt über `all` für den ganzen Host. Für
normal adressierte Interfaces ändert sich nichts; brechen würde es einen
Aufbau, der bewusst auf ARP-Flux baut – eine VIP auf `lo` oder `dummy0`, die
eine echte NIC beantworten soll. Auf Unraid gegenprüfen, bevor es dauerhaft
gesetzt wird.

Beides ist Laufzeitzustand und nach einem Reboot weg. Auf Unraid gehören die
Zeilen deshalb nach `/boot/config/go`, sonst steht die Lücke beim nächsten
Start wieder offen. Danach [verify/egress-test.sh](verify/egress-test.sh)
laufen lassen – der Weg Gast → Firewall-VM läuft innerhalb der Bridge und
sollte von `INPUT` unberührt bleiben, aber das ist billiger zu prüfen als
anzunehmen.

**Innerhalb eines Segments schützt der Regelsatz nichts.** Die Regel
`Edge -> Cluster-Ingress` erkennt den Edge an `ip saddr $edge_ip`. Der
Anti-Spoofing-Block stellt sicher, dass der Absender aus `10.10.20.0/24` kommt –
ein *zweiter* Gast in der DMZ könnte sich aber als `10.10.20.10` ausgeben. Ein
L3-Gateway kann das nicht unterscheiden. Konsequenz: in `fw-dmz` gehört nur die
Edge-VM, und die zweite Durchsetzung bleiben mTLS und die Cilium-NetworkPolicy
([Edge-Architektur](../../k8s/Edge-Architektur.md), Abschnitt 4).

## Offene Punkte

- Die Edge-VM (Traefik + CrowdSec AppSec) existiert noch nicht; `10.10.20.10`
  ist reserviert, aber unbelegt. Bis dahin läuft nichts über 443.
- `syslog_remote` braucht einen Syslog-Empfänger im Loki-Stack (Promtail bzw.
  Alloy mit `loki.source.syslog`).
- Die IP-Freigabe der Fritzbox (`443 → 192.168.178.6`) und die
  Split-DNS-Einträge in AdGuard sind manuelle Schritte an Geräten, die nicht in
  diesem Repo verwaltet werden.
