# Edge-VM

Der Torwächter aus Zone 2 des Sicherheitskonzepts
([../../k8s/homelab-sicherheitskonzept.html](../../k8s/homelab-sicherheitskonzept.html),
Abschnitt „Edge-VM"), vollständig über Terraform erzeugt: Debian 13 minimal,
zwei Beine, die sechsstufige Verarbeitungskette — und sonst nichts.

Läuft wahlweise lokal auf `qemu:///system` oder auf Unraid. Umgestellt wird über
`libvirt_uri` und `lan_bridge`, die VM-Definition bleibt identisch.

## Was hier entsteht

| Ressource | Wert |
|---|---|
| libvirt-Netz | `edge-dmz`, isoliert, ohne Adresse auf dem Host, ohne DHCP |
| VM | `edge1`, 2 vCPU, 1,5 GB RAM, 10 GB Disk, UEFI/q35 |
| Disks | qcow2-Dateien in `pool_path` (Unraid: `/mnt/cache/domains`) |
| LAN-Bein | `192.168.178.20` an Bridge `br0` — Ziel der Fritzbox-Freigabe |
| DMZ-Bein | `10.10.20.2` an Bridge `virbr-edgedmz` — Gegenstelle: `ingress-public` |
| OS | Debian 13 genericcloud, Snapshot gepinnt in [variables.tf](variables.tf) |
| Regelsatz | `table inet edge` in `/etc/nftables.conf` |
| Proxy | Traefik als systemd-Unit, unprivilegiert, nur `CAP_NET_BIND_SERVICE` |
| Abwehr | CrowdSec-Agent, AppSec auf zwei Listenern, Firewall-Bouncer auf nftables |
| PKI | ACME DNS-01 über acme-dns, mTLS-Client-Zertifikat mit 24 h Laufzeit |
| Zugang | SSH nur aus `admin_sources`, nur auf dem LAN-Bein, nur Public-Key |

Und was **nicht** entsteht: keine Storage-Mounts, kein VNC/SPICE auf dem
Hypervisor, kein Passwort-Login, kein Root-Login, kein IPv6, **kein Docker**.

## Die Verarbeitungskette

| Stufe | Umsetzung | Datei |
|---|---|---|
| 1 nftables | eingehend nur 443, ausgehend nur Cluster, Resolver, NTP, ACME | [templates/nftables.nft.tftpl](templates/nftables.nft.tftpl) |
| 2 CrowdSec-Bouncer | nftables-Set (Firewall-Bouncer) plus Plugin-Bouncer in Traefik | [templates/crowdsec/firewall-bouncer.yaml.tftpl](templates/crowdsec/firewall-bouncer.yaml.tftpl) |
| 3 TLS-Terminierung | ein Zertifikat je Name, DNS-01 über acme-dns, TLS 1.2/1.3, HSTS | [templates/traefik/traefik.yml.tftpl](templates/traefik/traefik.yml.tftpl) |
| 4 Host-Whitelist | `sniStrict` ohne Default-Zertifikat — fremde Namen enden im Handshake | [templates/traefik/dynamic/tls.yml.tftpl](templates/traefik/dynamic/tls.yml.tftpl) |
| 5 AppSec / WAF | zwei Listener: Virtual Patching + CRS, und Virtual Patching allein | [templates/crowdsec/acquis-appsec.yaml.tftpl](templates/crowdsec/acquis-appsec.yaml.tftpl) |
| 6 Rate Limiting, Routing | pfadabhängig, dann per mTLS an `ingress-public` | [templates/traefik/dynamic/](templates/traefik/dynamic/) |

**Warum Binaries statt Docker.** Ein Container-Daemon in der exponierten Zone
wäre ein zweiter Root-Prozess mit eigenem Netzwerk-Stack — und Docker setzt
beim Start `net.ipv4.ip_forward` auf `1`. Genau der Wert muss hier `0` bleiben:
Die Edge-VM ist ein Proxy, kein Router. Stünde er auf `1`, gäbe es neben dem
Proxy einen zweiten Weg von außen nach innen, an TLS-Terminierung, WAF und
CrowdSec vorbei. `verify/assert-ruleset.sh` prüft den Wert bei jedem Lauf.

## Voraussetzungen

- `terraform`, `libvirt`/`qemu-kvm`, Benutzer in den Gruppen `libvirt` und `kvm`
  (siehe [../ubuntu-desktop/vorraussetzungen.md](../ubuntu-desktop/vorraussetzungen.md))
- Ein Weg ins Heimnetz: eine Bridge (`lan_bridge`, auf Unraid `br0`) oder -
  wenn Bridging dort aus ist - macvtap auf dem physischen Interface
  (`lan_macvtap_dev`, meist `bond0`). `ip -br link` auf dem Host zeigt, was es gibt
- Ein Verzeichnis für die VM-Disks (`pool_path`, auf Unraid der Share
  `domains`). Den libvirt-Pool darüber legt dieses Modul selbst an — Unraid
  bringt keinen mit. Existiert schon einer, `manage_pool = false` setzen
- Eine freie, feste Adresse im Heimnetz außerhalb des Fritzbox-DHCP-Bereichs
- UEFI-Firmware, die libvirt findet. Auf Unraid scheitert die automatische
  Auswahl (fehlende NVRAM-Vorlage) — dort `efi_loader` und
  `efi_vars_template` setzen, siehe
  [../../k8s/INBETRIEBNAHME.md](../../k8s/INBETRIEBNAHME.md)

## Erstellen

```bash
cd vm/edge
cp terraform.tfvars.example terraform.tfvars   # anpassen, SSH-Key eintragen
terraform init
terraform apply
```

Der erste Boot dauert ein paar Minuten (Paketinstallation durch cloud-init).
Zusehen kann man über die serielle Konsole:

```bash
virsh -c qemu:///system console edge1
```

## Reihenfolge

Die Kette wird von unten nach oben scharf, und die Portfreigabe kommt **nicht**
zuerst. `terraform output naechste_schritte` gibt dieselbe Liste mit den
konkreten Adressen aus.

1. `terraform apply`
2. Ersten cloud-init-Lauf abwarten — bis `systemctl enable --now nftables`
   durch ist, läuft die VM ungefiltert. Fertig ist sie, wenn
   `cloud-init status --wait` `done` meldet.
3. `verify/assert-ruleset.sh` und `verify/egress-test.sh` — beide grün
4. Talos-Node ein zweites Bein in `virbr-edgedmz` geben, `ingress-public` an
   `10.10.20.3` binden, mit `ss -lntp` gegenprüfen; ein Verbindungsversuch aus
   dem LAN muss scheitern
5. ACME-DNS-Instanz aufsetzen, `_acme-challenge`-CNAMEs anlegen
   (`terraform output acme_challenge_cnames`), erste Läufe gegen das
   **Staging**-Verzeichnis von Let's Encrypt
6. Erst jetzt in der Fritzbox 443/TCP auf `lan_ip` freigeben — und IPv6
   getrennt prüfen: „Host komplett freigeben" öffnet mehr als gedacht.
   Danach `verify/proxy-test.sh <öffentlicher-name>`
7. step-ca im Cluster, `step_ca_url` und `step_ca_fingerprint` setzen,
   `terraform apply`, dann auf der VM `sudo edge-mtls-bootstrap <token>`
8. CrowdSec-LAPI im Cluster, `sudo edge-crowdsec-connect …`, dann
   `crowdsec_bouncer_armed = true` und `terraform apply`
9. Ein bis zwei Wochen `cscli alerts list` auswerten, danach
   `sudo edge-crowdsec-connect --arm-firewall-bouncer`
10. Zum Schluss `egress_targets` füllen und `egress_open = false`

Die Schritte 5 bis 9 hängen an Dingen im Cluster, die es noch nicht gibt. Bis
dahin läuft die VM sinnvoll weiter: Traefik startet auch ohne Zertifikate und
ohne Router — er nimmt dann nur Verbindungen an, die am `sniStrict`-Filter
scheitern.

## Verifikation

```bash
vm/edge/verify/assert-ruleset.sh              # Drift zwischen Repo, Datei und Kernel
vm/edge/verify/egress-test.sh                 # was die VM erreicht und was nicht
vm/edge/verify/proxy-test.sh cloud.domain.de  # Stufen 3-6 am laufenden Proxy
```

Das erste Skript vergleicht `/etc/nftables.conf` und die sshd-Ergänzung gegen
die Terraform-Outputs und lädt den Regelsatz zusätzlich in eine wegwerfbare
Network-Namespace, um ihn kanonisch gegen den laufenden Zustand zu stellen —
damit fällt auch ein `nft add rule` von Hand auf.

Das zweite fährt die Proben von der VM aus: Cluster und interner Resolver
erreichbar, Heimnetz, Gateway-Oberfläche und öffentliches DNS nicht.
Unterschieden wird über die Zeit — ein gesperrtes Ziel läuft in den Timeout, ein
erlaubtes antwortet sofort, notfalls mit „connection refused".

Das dritte prüft Verhalten statt Konfiguration. Die beiden wichtigsten Proben
sind die aus dem Konzept:

- **Gefälschter `X-Forwarded-For`.** Der Request geht mit
  `X-Forwarded-For: 192.168.178.254` raus, danach liest das Skript den
  Access-Log-Eintrag auf der VM. Steht dort die gefälschte Adresse, bestimmt
  der Angreifer per Kopfzeile, als welche IP er bewertet wird — und die
  zentrale Abwehrschicht ist mit einer Zeile abgeschaltet.
- **Fremder Hostname und direkter IP-Zugriff.** Beide müssen im
  TLS-Handshake enden, nicht in einer HTTP-Antwort.

Zusätzlich: TLS-Version, genau ein HSTS-Header, keine doppelten
Sicherheits-Header, Restlaufzeit des Client-Zertifikats, Zustand von Timer,
Agent und Bouncer. Mit `--rate` kommt eine Rate-Limit-Probe dazu (erzeugt Last
und ggf. Alarme auf die eigene IP).

## Der Egress-Filter

Das ist Stufe 1 der Verarbeitungskette und der eigentliche Inhalt dieses Moduls.
Ausgehend erlaubt sind:

| Ziel | Port | Wofür |
|---|---|---|
| `cluster_ingress_ip` | 443 | `ingress-public`, mTLS mit Client-Zertifikat |
| `cluster_ingress_ip` | 8443 | CrowdSec-LAPI: Alarme rein, Entscheidungen raus |
| `step_ca_ip` | 9000 | interne CA, Erneuerung des Client-Zertifikats |
| `dns_servers` | 53 | interner Resolver mit Query-Logging und Blocklist |
| `ntp_servers` | 123 | ohne korrekte Zeit kein ACME |
| öffentliche Ziele | 80, 443 | ACME, CrowdSec-Hub, Paketquellen |

Alles andere in `10/8`, `172.16/12`, `192.168/16`, `169.254/16` und `100.64/10`
wird verworfen und protokolliert. Daran hängt die Zusage „kein LAN, keine
Shares, keine Unraid-Oberfläche".

**`egress_open` ist der Bootstrap-Schalter.** Solange er auf `true` steht, darf
die VM beliebige *öffentliche* Ziele auf 80/443 erreichen — private bleiben auch
dann gesperrt. Das ist Absicht: ACME-Endpunkte, CrowdSec-Hub und Debians
Paketquellen liegen auf CDNs mit wechselnden Adressen, und ein Regelsatz löst
keine Namen auf. Der Weg zum Zielzustand:

```bash
ssh edge@192.168.178.20 sudo nft list table inet edge   # Counter lesen
# egress_targets füllen, egress_open = false, terraform apply
vm/edge/verify/egress-test.sh
```

Was der Filter nicht leistet, steht so auch im Konzept: Er verhindert Reverse
Shells, Nachladen von Werkzeug und LAN-Scans — kein Exfiltrieren. Über DNS und
die erlaubten TLS-Ziele bleibt ein Kanal offen. Deshalb `counter` auf jeder
Egress-Regel.

## Zertifikate, Schlüssel und die drei Bootstrap-Schritte

Alles, was ein Geheimnis ist, kommt **nicht** aus Terraform. Es entsteht im
Cluster und wird auf der VM eingetragen — sonst lägen LAPI-Zugangsdaten und
Tokens im Terraform-State und in der Seed-ISO im Storage-Pool. Dafür gibt es
drei Skripte auf der Maschine:

```bash
# 1. Client-Zertifikat von der internen CA (einmalig)
step ca token edge1.dmz              # im Cluster, läuft nach Minuten ab
sudo edge-mtls-bootstrap <token>     # auf der Edge

# 2. Agent und Bouncer an die LAPI im Cluster hängen
cscli machines add edge1 --password '<pw>'   # im Cluster
cscli bouncers add edge1-firewall
cscli bouncers add edge1-traefik
sudo edge-crowdsec-connect \
  --agent-password '<pw>' --firewall-key '<key>' --traefik-key '<key>'

# 3. nach ein bis zwei Wochen Beobachtung
sudo edge-crowdsec-connect --arm-firewall-bouncer
```

**ACME über acme-dns.** Traefik holt je öffentlichem Namen ein Zertifikat per
DNS-01, mit dem lego-Provider `acmedns`. Die Kontodaten liegen unter
`/var/lib/traefik/acme-dns.json`; beim ersten Lauf registriert lego dort ein
Konto und nennt die Subdomain, auf die der `_acme-challenge`-CNAME zeigen muss.
Die Edge bekommt damit **keinen** Provider-Token: Wer sie übernimmt, kann
Zertifikate für die ohnehin öffentlichen Namen ausstellen — mehr nicht.

Dazu gehört `acme_dns_api_base` in `terraform.tfvars`. Der lego-Provider liest
Adresse und Ablageort seiner Kontodaten **ausschließlich aus der Umgebung**, in
`traefik.yml` lässt sich das nicht ausdrücken; die systemd-Unit setzt beides als
`ACME_DNS_API_BASE` und `ACME_DNS_STORAGE_PATH`. Bleibt die Variable leer, legt
Traefik den Resolver `acmedns` gar nicht erst an und jeder Router bleibt ohne
Zertifikat — sichtbar daran, dass `proxy-test.sh` schon an der ersten Probe
scheitert.

**Erneuerung des Client-Zertifikats.** `edge-cert-renew.timer` prüft stündlich,
`step ca renew` schreibt erst bei weniger als `cert_renew_before` Restlaufzeit.
Authentifiziert wird mit dem noch gültigen Zertifikat (mTLS) — auf der Edge
liegt deshalb nie ein Provisioner-Passwort, mit dem sich Zertifikate für andere
Namen ausstellen ließen. Läuft das Zertifikat doch einmal ab, hilft nur ein
neues Token: Ein abgelaufenes Zertifikat soll sich nicht selbst wiederbeleben
können. Nach jeder Erneuerung fasst der Hook
`dynamic/servers-transport.yml` an — Traefik liest Zertifikatsdateien nur beim
Laden der dynamischen Konfiguration, ein neues Zertifikat auf der Platte allein
reicht nicht.

**`crowdsec_bouncer_armed` ist ein eigener Schalter.** Das Plugin prüft beim
Laden, ob die Key-Datei existiert, und verweigert sonst den Dienst — jeder
Router, der es einbindet, wäre dann kaputt. Deshalb: erst
`edge-crowdsec-connect`, dann die Variable auf `true` und `terraform apply`.
Bis dahin laufen die Router mit TLS, Header-Hygiene und Rate Limiting, aber
ohne Bouncer und ohne WAF. Das ist ein sichtbarer Zwischenzustand, kein
stiller.

## Die Cluster-Seite

Dieses Modul ist die Außengrenze. Die Gegenstelle steht in
[../talos](../talos) (Node und Talos-Config) und
[../../k8s/platform](../../k8s/platform) (alles, was im Cluster läuft). Was
dort die Zusagen dieses Moduls beantwortet:

| Hier | Dort |
|---|---|
| `cluster_ingress_ip` = `10.10.20.3` | `ingress-public` per `hostPort`/`hostIP` an genau diese Adresse gebunden, Talos-Ingress-Firewall lässt nur `10.10.20.2` durch |
| Client-Zertifikat der Edge | `tls.options.default` mit `clientAuth: RequireAndVerifyClientCert` gegen die interne CA — gilt für jeden Router auf `ingress-public` |
| `step_ca_url` / `step_ca_fingerprint` | step-ca im Cluster, über `ingress-public` als TCP-Passthrough auf Port 9000 |
| `crowdsec_lapi_port` = `8443` | LAPI hinter derselben mTLS-Strecke, plus NetworkPolicy auf Port und Quell-Namespace |
| Agent auf der Edge | eigene Machine-Credentials, kürzere Sperrdauer für Edge-Alarme, Whitelist der Verwaltungs-IP als LAPI-Profil |
| — | Kyverno-Regel auf `ingressClassName: public`, App-Parser als DaemonSet dort, wo die Logs entstehen |

Die Reihenfolge über alle drei Module steht in
[../../k8s/platform/README.md](../../k8s/platform/README.md); die drei
Bootstrap-Schritte oben (`edge-mtls-bootstrap`, `edge-crowdsec-connect`)
bekommen ihre Werte aus `k8s/platform/scripts/`.

## Was die Kette nicht leistet

- **Der Firewall-Bouncer kann aussperren.** Er setzt Entscheidungen der LAPI in
  nftables um und sieht dabei nur Adressen, keine Kopfzeilen. Die Whitelist im
  Traefik-Plugin (`clientTrustedIPs`) schützt davor nicht — sie greift eine
  Ebene höher. Der Notzugang ist deshalb bewusst keiner, der über das Netz
  führt: `virsh console edge1` auf dem Hypervisor.
- **`admin_sources` beantwortet zwei Fragen auf einmal.** Die Liste steuert, wer
  SSH erreichen darf — und sie landet als `clientTrustedIPs` im
  CrowdSec-Plugin, wo sie Bouncer *und* AppSec überspringt. Steht dort wie im
  Standardfall das ganze Heimnetz, hat jedes Gerät darin die Abwehrschicht nicht
  mehr vor sich, denn über Split-DNS erreichen LAN-Clients dieselben
  öffentlichen Namen wie das Internet. Das passt zum Konzept, das das LAN als
  vertraute Zone führt, und verhindert, dass ein Test aus dem eigenen Netz den
  eigenen Zugang sperrt. Wer es enger will, trägt einzelne Adressen ein — das
  verschärft dann aber auch die SSH-Regel.
- **`/remote.php/*` bleibt der Weg um den Login-Schutz herum.** Auf demselben
  Pfad liegen großzügiges Rate Limiting und eine bis auf Virtual Patching
  abgeschaltete WAF, und er akzeptiert Basic-Auth mit denselben Passwörtern wie
  das Webformular. Bewusst in Kauf genommen, um den Sync nicht zu brechen; die
  Auflösung über Antwortcode-Staffelung und erzwungene App-Passwörter gehört in
  den Cluster.
- **Kein Schutz gegen volumetrische Angriffe.** Das ist der Preis von
  Entscheidung E1 (CrowdSec statt CDN) und ändert sich hier nicht.

## Bewusste Entscheidungen

**Zwei Beine, eines davon im flachen LAN.** Das Konzept zeichnet die Edge-VM in
einer DMZ ohne gemeinsames Uplink mit der internen Zone. Die Strecke nach innen
ist auch genau so gebaut: ein isoliertes libvirt-Netz ohne Adresse auf dem Host,
ohne DHCP, mit genau zwei Teilnehmern. Nach außen geht das nicht: Die Fritzbox
kann eine Portfreigabe nur auf eine Adresse in ihrem eigenen Netz richten, und
eine vorgelagerte Router-VM gibt es in diesem Stand nicht mehr. Das LAN-Bein
liegt deshalb im Heimnetz, und die Grenze „Edge erreicht kein LAN" wird
host-basiert durchgesetzt (nftables output-Chain, `rp_filter`, `ip_forward = 0`)
statt topologisch.

Das ist schwächer, und zwar messbar: Wer auf der VM Root wird, ist eine
`nft flush chain`-Zeile vom Heimnetz entfernt — bei einer Trennung auf
Netzebene wäre er es nicht. Das gehört zu den Restrisiken und ist der Punkt,
an dem sich der im Konzept erwähnte zweite kleine Rechner am stärksten
auszahlen würde. Was die Konstruktion trotzdem trägt: Der Angreifer muss dafür
erst aus Traefik heraus Root werden, und die Sperren des CrowdSec-Bouncers
setzt weiterhin eine Maschine durch, die er dafür übernehmen müsste.

**`ip_forward = 0`, dauerhaft.** Die Edge-VM ist ein Proxy, kein Router. Sie
beendet die Verbindung aus dem Internet und baut eine neue in die DMZ auf.
Stünde hier `1`, gäbe es neben dem Proxy einen zweiten Weg von außen nach innen
— an TLS-Terminierung, WAF und CrowdSec vorbei. `verify/assert-ruleset.sh`
prüft den Wert deshalb bei jedem Lauf.

**Regeln über Adressen statt über Interface-Namen.** `enp1s0`/`enp2s0` hängen an
der PCI-Reihenfolge. Der Regelsatz unterscheidet die Beine über die Zieladresse,
und dieselben Adressen stehen in der cloud-init-Netzwerkkonfiguration —
beide Seiten kommen aus derselben Terraform-Variablen und können nicht
auseinanderlaufen. Die Interfaces selbst werden per MAC-Match zugeordnet.

**Kein VNC, kein SPICE.** Die VM braucht keine Grafik. Ein zusätzlicher
lauschender Socket auf dem Hypervisor ist genau das, was diese Zone nicht haben
soll. Diagnose läuft über `virsh console` — und das ist zugleich der Notzugang,
den das Konzept fordert: ein Weg, der nicht über die gesperrte IP führt und aus
dem Internet gar nicht erreichbar ist.

**Image-Snapshot gepinnt statt `latest`.** Der Snapshot geht in den
Volume-Namen ein. Damit ist nachvollziehbar, welches Image in der laufenden VM
steckt — und ein Wechsel ist eine sichtbare Änderung im Repo statt eines
stillen Unterschieds beim nächsten Neuaufbau.

**Security-Updates automatisch, Reboots nicht.** `unattended-upgrades` läuft,
`Automatic-Reboot` steht auf `false`. Ein Reboot dieser VM nimmt alle
öffentlichen Dienste mit; der Zeitpunkt gehört zu einer Entscheidung, nicht zu
einem Cronjob. Kernel-Updates greifen entsprechend erst nach dem nächsten
manuellen Neustart.

**Binaries mit Prüfsumme aus dem Repo.** Traefik und step-cli werden von GitHub
geladen und gegen eine SHA256 aus [variables.tf](variables.tf) geprüft — nicht
gegen die Prüfsummendatei neben dem Release. Wer das Release austauschen kann,
kann auch die Datei daneben austauschen; der Wert im Repo ist der einzige
Vergleichspunkt, den ein Angreifer nicht mitverändert. Renovate meldet neue
Versionen, mergt sie aber nicht automatisch: Die Prüfsumme muss von Hand
nachgezogen werden.

**Zwei AppSec-Listener statt einer Regel mit Ausnahmen.** Der pfadabhängige
Zuschnitt hängt in CrowdSec am Listener, nicht am Request. Deshalb lauscht der
Agent auf `127.0.0.1:7422` mit Virtual Patching **und** CRS und auf
`127.0.0.1:7423` nur mit Virtual Patching; Traefik schickt je nach Router an den
einen oder anderen Port. Beide nur auf dem Loopback — ein AppSec-Port aus dem
Netz ließe sich umgehen oder direkt befragen.

## Betrieb

```bash
# Zustand ansehen
ssh edge@192.168.178.20 sudo nft list table inet edge
ssh edge@192.168.178.20 sudo journalctl -k -g 'nft-'      # was verworfen wurde
ssh edge@192.168.178.20 sudo journalctl -u traefik -f
ssh edge@192.168.178.20 sudo cscli alerts list            # was CrowdSec gesehen hat
ssh edge@192.168.178.20 sudo cscli metrics                # inkl. AppSec-Zähler

# Nach jeder Konfigurationsänderung
terraform apply && vm/edge/verify/assert-ruleset.sh

# Nach einem Versions-Update (Traefik, step-cli)
ssh edge@192.168.178.20 sudo /usr/local/sbin/edge-install-stack
```

Änderungen an `templates/` oder an den Variablen ändern den Hash der Seed-ISO.
Terraform legt dann eine neue an und die VM zieht die Konfiguration beim
nächsten Start vollständig neu — cloud-init würde sie bei gleicher `instance-id`
sonst überspringen. Für Traefik reicht das nicht immer: Die dynamische
Konfiguration liest er im laufenden Betrieb neu ein, die statische
(`traefik.yml`) erst beim Neustart.

**Neuausrollen ist die Reparaturstrategie.** Der Prüfstein aus dem Konzept:
Löscht man die VM und rollt sie neu aus, darf außer den ACME-Zertifikaten nichts
verloren gehen. Solange das gilt, ist ein Verdacht kein Vorfall, sondern ein
`terraform destroy && terraform apply` — danach die drei Bootstrap-Schritte
oben, in dieser Reihenfolge. Verloren gehen dabei die acme-dns-Kontodaten unter
`/etc/traefik/secrets/`; wer das vermeiden will, sichert genau diese Datei.

## Aufräumen

```bash
terraform destroy
```

Entfernt VM, Disks, Seed-ISO und das DMZ-Netz. Der Pool wird nur abgemeldet,
nicht gelöscht (`destroy.delete = false`) — auf Unraid ist sein Ziel ein
produktiver Share. Was an Dateien übrig bleibt, ist das Basis-Image; wer auch
das los will, entfernt es von Hand aus `pool_path`.
