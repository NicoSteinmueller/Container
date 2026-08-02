#
# Identität
#
variable "vm_name" {
  description = "Name der VM. Geht in Domain-, Volume- und Hostnamen ein."
  type        = string
  default     = "edge1"
}

variable "timezone" {
  description = "Zeitzone der VM. Relevant für die Logzeitstempel, die später CrowdSec auswertet."
  type        = string
  default     = "Europe/Berlin"
}

#
# libvirt
#
variable "libvirt_uri" {
  description = "libvirt-Connection-URI. Lokal qemu:///system, auf Unraid qemu+ssh://root@<host>/system."
  type        = string
  default     = "qemu:///system"
}

variable "libvirt_pool" {
  description = <<-EOT
    Name des Storage-Pools für Basis-Image, System-Disk und Seed-ISO.
    Bei manage_pool = true wird er unter diesem Namen angelegt, sonst muss er
    bereits existieren (`virsh pool-list --all`).
  EOT
  type        = string
  default     = "homelab"
}

variable "manage_pool" {
  description = <<-EOT
    Den Storage-Pool von Terraform anlegen lassen.

    Auf Unraid nötig: Dort gibt es ab Werk keinen einzigen libvirt-Pool - VMs
    werden über absolute Pfade definiert -, und ohne Pool bricht der erste
    Apply mit "Storage pool not found" ab.

    Auf false setzen, wenn ein Pool schon existiert (typisch bei einem
    lokalen Testlauf auf qemu:///system, wo "default" auf
    /var/lib/libvirt/images zeigt) - dann zusätzlich libvirt_pool anpassen.

    Genau ein Modul soll den Pool verwalten. vm/talos verwendet denselben
    Pool und legt ihn deshalb standardmäßig nicht an.
  EOT
  type        = bool
  default     = true
}

variable "pool_path" {
  description = <<-EOT
    Verzeichnis, in dem die Disks liegen. Auf Unraid der Share `domains` -
    dort erwartet die VM-Oberfläche ihre Images, und dorthin schauen die
    Backup-Plugins.

    Liegt der Share wie üblich auf einem Cache-Pool
    (shareUseCache="only" in /boot/config/shares/domains.cfg), ist
    /mnt/cache/domains der schnellere Weg zum selben Ort: Er umgeht die
    shfs-FUSE-Schicht. /mnt/user/domains funktioniert ebenso und bleibt
    richtig, falls der Share später auf das Array wandert.
  EOT
  type        = string
  default     = "/mnt/user/domains"

  #
  # Kreuzprobe gegen den häufigsten Fehlgriff: Unraid-Pfad, aber der lokale
  # Hypervisor. Ohne diese Prüfung legt Terraform den Pool klaglos auf der
  # Arbeitsstation an - und der Fehler fällt erst auf, wenn die VM nicht
  # startet, weil dort weder die Bridge noch die OVMF-Dateien existieren.
  #
  validation {
    condition = !(
      (startswith(var.pool_path, "/mnt/user/") || startswith(var.pool_path, "/mnt/cache/")) &&
      (var.libvirt_uri == "qemu:///system" || var.libvirt_uri == "qemu:///session")
    )
    error_message = "pool_path zeigt auf einen Unraid-Share, libvirt_uri aber auf den lokalen Hypervisor. Entweder libvirt_uri auf qemu+ssh://root@<unraid>/system setzen oder pool_path auf ein lokales Verzeichnis."
  }
}

#
# Image
#
# Bewusst gepinnt: Der Snapshot geht in den Volume-Namen ein. Ein neuer Wert
# baut beim nächsten `terraform apply` die VM neu - das ist ein Wartungsfenster,
# in dem die öffentlichen Dienste nicht erreichbar sind.
#
variable "debian_version" {
  description = "Debian-Hauptversion im Dateinamen des Cloud-Images."
  type        = string
  default     = "13"
}

variable "debian_codename" {
  description = "Debian-Codename im Pfad des Cloud-Images."
  type        = string
  default     = "trixie"
}

variable "debian_image_snapshot" {
  description = <<-EOT
    Snapshot-Stand des Cloud-Images. Verfügbare Stände:
    https://cloud.debian.org/images/cloud/trixie/
    Der Wert steht bewusst nicht auf "latest" - sonst wäre nicht nachvollziehbar,
    welches Image in der laufenden VM steckt.
  EOT
  type        = string
  default     = "20260722-2547"
}

#
# VM-Dimensionierung
#
# 1,5 GB entspricht der Zeile "Edge-VM 1,5 GB" aus dem Ressourcenkapitel des
# Konzepts. Traefik und die beiden CrowdSec-Prozesse liegen zusammen bei rund
# 500 MB; der Rest ist Puffer für Page-Cache und AppSec-Regelsätze.
#
variable "vm_memory_mib" {
  description = "RAM der VM in MiB."
  type        = number
  default     = 1536
}

variable "vm_vcpu" {
  description = "Anzahl vCPUs. TLS-Terminierung profitiert vom zweiten Kern."
  type        = number
  default     = 2
}

variable "vm_disk_gib" {
  description = "Größe der System-Disk in GiB (qcow2, dünn alloziert). Platz für Logs, ACME-Zertifikate und die CrowdSec-Blocklist."
  type        = number
  default     = 10
}

#
# LAN-Bein - Heimnetz hinter der Fritzbox
#
variable "lan_bridge" {
  description = <<-EOT
    Vorhandene Host-Bridge für das LAN-Bein (Unraid: "br0"). Vorher mit
    `ip -br link` auf dem Host gegenprüfen.
    Auf null setzen, um stattdessen lan_libvirt_network zu verwenden - das ist
    der Weg für einen lokalen Testlauf ohne Bridge.
  EOT
  type        = string
  default     = "br0"
}

variable "lan_libvirt_network" {
  description = "Vorhandenes libvirt-Netz als LAN-Ersatz, wenn lan_bridge null ist (lokaler Test: \"default\")."
  type        = string
  default     = "default"
}

variable "lan_macvtap_dev" {
  description = <<-EOT
    Physisches Interface für ein macvtap-Bein statt einer Bridge - der Weg für
    Unraid-Hosts, auf denen Bridging abgeschaltet ist (Settings -> Network
    Settings -> "Enable bridging: No"). Dort gibt es kein br0, sondern nur
    bond0 bzw. ethX und Unraids eigenes vhost0.

    Gesetzt (z. B. "bond0") hat Vorrang vor lan_bridge und
    lan_libvirt_network. Gegenprüfen mit `ip -br link` auf dem Host.

    Was macvtap bedeutet, und das ist kein Detail: Die VM erreicht das LAN
    und das LAN erreicht die VM - aber die VM und der Hypervisor-Host sehen
    einander nicht. Für die Edge-VM ist das eher erwünscht (das Konzept
    verlangt ohnehin "kein LAN, keine Shares, keine Unraid-Oberfläche"), für
    den Talos-Node heißt es: NFS-Exporte vom selben Host sind über dieses
    Bein nicht erreichbar. Docker-Container in einem macvlan-Netz auf
    demselben Parent (auf Unraid der Netzwerktyp "bond0") sind dagegen
    erreichbar - der interne Resolver darf also dort liegen.
  EOT
  type        = string
  default     = null
}

variable "lan_cidr" {
  description = "Heimnetz. Der Regelsatz sperrt den Egress dorthin - die Edge-VM steht zwar darin, hat darin aber nichts zu suchen."
  type        = string
  default     = "192.168.178.0/24"

  validation {
    condition     = can(cidrhost(var.lan_cidr, 0))
    error_message = "lan_cidr muss ein CIDR sein, z. B. 192.168.178.0/24."
  }
}

variable "lan_ip" {
  description = "Feste Adresse der Edge-VM im Heimnetz. Ziel der Fritzbox-Portfreigabe. Muss außerhalb des Fritzbox-DHCP-Bereichs liegen."
  type        = string
  default     = "192.168.178.20"
}

variable "lan_gateway" {
  description = "Default-Gateway, in der Regel die Fritzbox."
  type        = string
  default     = "192.168.178.1"
}

variable "dns_servers" {
  description = <<-EOT
    Interner Resolver. Bewusst nicht 1.1.1.1 o. ä.: Das Konzept verlangt DNS
    ausschließlich zum internen Resolver mit Query-Logging und Blocklist, weil
    DNS der Kanal ist, den der Egress-Filter nicht schließen kann.
  EOT
  type        = list(string)
  default     = ["192.168.178.2"]

  validation {
    condition     = length(var.dns_servers) > 0
    error_message = "Mindestens ein Resolver nötig, sonst kommt die VM nicht an ACME."
  }
}

variable "ntp_servers" {
  description = "NTP-Quellen. Zeit muss stimmen, sonst schlagen ACME und die 24-h-Client-Zertifikate fehl."
  type        = list(string)
  default     = ["192.168.178.1"]

  validation {
    condition     = length(var.ntp_servers) > 0
    error_message = "Mindestens eine NTP-Quelle nötig."
  }
}

#
# DMZ-Bein - isolierte Strecke zum Cluster
#
variable "dmz_network_name" {
  description = "Name des libvirt-Netzes zwischen Edge-VM und Talos-Node."
  type        = string
  default     = "edge-dmz"
}

variable "dmz_bridge" {
  description = "Name der Linux-Bridge des DMZ-Netzes (max. 15 Zeichen)."
  type        = string
  default     = "virbr-edgedmz"
}

variable "dmz_cidr" {
  description = "Adressbereich der Strecke Edge -> Cluster. Klein gehalten: hier stehen genau zwei Maschinen."
  type        = string
  default     = "10.10.20.0/29"

  validation {
    condition     = can(cidrhost(var.dmz_cidr, 0))
    error_message = "dmz_cidr muss ein CIDR sein, z. B. 10.10.20.0/29."
  }
}

variable "edge_dmz_ip" {
  description = "Adresse der Edge-VM im DMZ-Segment."
  type        = string
  default     = "10.10.20.2"
}

variable "cluster_ingress_ip" {
  description = <<-EOT
    Adresse, an die ingress-public im Talos-Node gebunden ist. Die einzige
    Adresse, die die Edge-VM jenseits von Resolver und NTP erreichen darf.
    Gegenprobe im Cluster: `ss -lntp` auf dem Node, plus ein Verbindungsversuch
    aus dem LAN, der scheitern muss.
  EOT
  type        = string
  default     = "10.10.20.3"
}

variable "cluster_ingress_port" {
  description = "Port von ingress-public. mTLS-terminiert, clientAuth gegen die interne CA."
  type        = number
  default     = 443
}

variable "crowdsec_lapi_port" {
  description = <<-EOT
    Port der CrowdSec-LAPI im Cluster. Zweite - und einzige weitere - Öffnung von
    der DMZ nach innen: Der Agent auf der Edge meldet Alarme, der Bouncer holt
    Entscheidungen. Im Cluster gehört darauf eine NetworkPolicy auf genau diesen
    Port und genau die Edge-Adresse.
  EOT
  type        = number
  default     = 8443
}

#
# Erreichbarkeit
#
variable "public_https_port" {
  description = "Port, auf dem die Edge-VM aus dem Internet erreichbar ist. Die Fritzbox reicht genau diesen weiter - Port 80 bleibt zu, weil ACME über DNS-01 läuft."
  type        = number
  default     = 443
}

variable "http3_enabled" {
  description = "Zusätzlich UDP/443 für HTTP/3 annehmen. Nur sinnvoll, wenn die Fritzbox UDP ebenfalls weiterreicht und Traefik QUIC anbietet."
  type        = bool
  default     = false
}

variable "admin_user" {
  description = "Login-Benutzer für die Administration. Kein Passwort, nur Public-Key."
  type        = string
  default     = "edge"
}

variable "ssh_authorized_keys" {
  description = "Public Keys für den Administrationszugang. Ohne mindestens einen Key gibt es keinen Weg auf die VM außer der seriellen Konsole."
  type        = list(string)

  validation {
    condition     = length(var.ssh_authorized_keys) > 0
    error_message = "Mindestens ein SSH-Key nötig - sonst ist die VM nach dem Apply nur über `virsh console` erreichbar."
  }
}

variable "admin_sources" {
  description = <<-EOT
    Quelladressen, die SSH auf der Edge-VM erreichen dürfen. Eng fassen: Das ist
    der einzige Verwaltungszugang, und er liegt im selben Netz, aus dem die
    Portfreigabe kommt. Leere Liste = kein SSH (nur serielle Konsole).
  EOT
  type        = list(string)
  default     = ["192.168.178.0/24"]
}

#
# Egress
#
variable "egress_open" {
  description = <<-EOT
    Bootstrap-Schalter für den ausgehenden Verkehr ins Internet.

    true  - ausgehend sind egress_tcp_ports zu beliebigen öffentlichen Zielen
            erlaubt (mit counter). Nötig, solange Paketquellen, ACME-Endpunkte
            und der CrowdSec-Hub noch nicht als IP-Sets feststehen; alle Ziele
            in privaten Netzen bleiben auch dann gesperrt.
    false - ausgehend nur noch zu egress_targets. Das ist der Zielzustand aus
            Stufe 1 der Verarbeitungskette ("Egress-Beschränkungen als IP-Sets").

    Vor dem Umschalten `nft list table inet edge` lesen: die Counter der
    Egress-Regel zeigen, was tatsächlich gebraucht wurde.
  EOT
  type        = bool
  default     = true
}

variable "egress_targets" {
  description = <<-EOT
    Erlaubte öffentliche Ziele als IP-Sets, wenn egress_open = false.
    Gemeint sind: die delegierte ACME-DNS-Instanz, die ACME-Endpunkte von
    Let's Encrypt, der CrowdSec-Hub und die Debian-Paketquellen.
    Hostnamen scheiden aus - der Regelsatz löst nichts auf.
  EOT
  type        = list(string)
  default     = []
}

variable "egress_tcp_ports" {
  description = "Zielports für ausgehende Verbindungen. 80 bleibt drin, weil Debians Paketquellen darüber laufen; eingehend ist 80 trotzdem zu."
  type        = list(number)
  default     = [80, 443]
}

#
# System
#
variable "mac_lan" {
  description = "MAC des LAN-Beins. Muss im QEMU-Bereich 52:54:00 liegen."
  type        = string
  default     = "52:54:00:e1:9e:01"
}

variable "mac_dmz" {
  description = "MAC des DMZ-Beins. Muss im QEMU-Bereich 52:54:00 liegen."
  type        = string
  default     = "52:54:00:e1:9e:02"
}

variable "extra_packages" {
  description = "Zusätzliche Pakete, die cloud-init installiert. Der Standardsatz ist bewusst klein."
  type        = list(string)
  default     = []
}

variable "auto_upgrade" {
  description = "unattended-upgrades für Security-Updates aktivieren. Reboots bleiben manuell - währenddessen ist nichts von außen erreichbar."
  type        = bool
  default     = true
}

variable "disable_ipv6" {
  description = <<-EOT
    IPv6 im Gast abschalten. Passend zum Konzept: Die Fritzbox filtert v6
    unabhängig von v4, und eine globale v6-Adresse auf der Edge-VM wäre an der
    Portfreigabe vorbei direkt erreichbar. Erst einschalten, wenn der v6-Pfad
    bewusst durchdacht ist.
  EOT
  type        = bool
  default     = true
}

# =====================================================================
# Stufen 2-6: Proxy, WAF, CrowdSec, mTLS
# =====================================================================

variable "stack_enabled" {
  description = <<-EOT
    Traefik, CrowdSec und die mTLS-Werkzeuge mit ausrollen. Auf false bleibt
    nur die gehärtete VM aus Stufe 1 übrig - nützlich, um die Netz- und
    Filterebene isoliert zu testen.
  EOT
  type        = bool
  default     = true
}

#
# Traefik
#
variable "traefik_version" {
  description = "Traefik-Release. Identisch zum Docker-Stack in traefik/compose.yml, damit beide Proxys dieselbe Version fahren."
  type        = string
  default     = "v3.7.10"
}

variable "traefik_sha256" {
  description = <<-EOT
    SHA256 von traefik_<version>_linux_amd64.tar.gz.
    Bewusst hier und nicht aus der Prüfsummendatei neben dem Release: Wer das
    Release austauschen kann, kann auch die Prüfsummendatei austauschen.
    Nach einem Versionswechsel neu setzen:
      curl -sL https://github.com/traefik/traefik/releases/download/<v>/traefik_<v>_checksums.txt | grep linux_amd64.tar.gz
  EOT
  type        = string
  default     = "01811bb12d44f17280550f425f5e3128d6c325f2665c09e67a651ca535f490ce"
}

variable "traefik_log_level" {
  description = "Log-Level von Traefik. DEBUG nur kurzfristig - das Access-Log ist die eigentliche Datenquelle."
  type        = string
  default     = "INFO"
}

variable "upload_timeout_seconds" {
  description = "Timeout für lange Requests. Muss groß genug für einen vollständigen Upload sein, sonst bricht die Synchronisation bei großen Dateien ab."
  type        = number
  default     = 3600
}

variable "tls_min_version" {
  description = "Minimale TLS-Version der Default-Optionen. TLS 1.3 allein sperrt ältere Immich- und Nextcloud-Clients aus."
  type        = string
  default     = "VersionTLS12"
}

variable "hsts_preload" {
  description = <<-EOT
    HSTS mit preload-Flag ausliefern. Standardmäßig aus: Preload ist eine
    Eintragung in Browser-Listen, die sich praktisch nicht zurücknehmen lässt
    und die gesamte Domain samt Subdomains auf HTTPS festlegt.
  EOT
  type        = bool
  default     = false
}

#
# Öffentliche Dienste
#
variable "domain" {
  description = "Basisdomain für die öffentlichen Namen."
  type        = string
  default     = "domain.de"
}

variable "public_services" {
  description = <<-EOT
    Die öffentlich erreichbaren Dienste. Jeder Eintrag erzeugt einen Router mit
    eigenem Zertifikat (kein Wildcard, Entscheidung E9).

      name          - technischer Name, taucht in Router- und Logeinträgen auf
      subdomain     - Name links vom Punkt; der Host ergibt sich mit `domain`
      host          - alternativ ein vollständiger Name, überschreibt subdomain
      strict_paths  - Pfade mit strengem Rate Limiting (Login)
      relaxed_paths - Pfade mit großzügigem Rate Limiting und AppSec nur mit
                      Virtual Patching (WebDAV, Sync)

    Default ist bewusst leer: Ohne Einträge fragt Traefik keine Zertifikate an
    und läuft nicht in ACME-Fehler, solange die ACME-DNS-Delegation fehlt.
    Beispiele in terraform.tfvars.example.
  EOT
  type = list(object({
    name          = string
    subdomain     = optional(string, "")
    host          = optional(string, "")
    strict_paths  = optional(list(string), [])
    relaxed_paths = optional(list(string), [])
  }))
  default = []

  validation {
    condition     = alltrue([for s in var.public_services : s.subdomain != "" || s.host != ""])
    error_message = "Jeder Dienst braucht subdomain oder host."
  }
}

variable "rate_limit_default" {
  description = "Rate Limit für den normalen Betrieb (Anfragen pro Quell-IP)."
  type = object({
    average = number
    burst   = number
    period  = string
  })
  default = {
    average = 100
    burst   = 50
    period  = "1m"
  }
}

variable "rate_limit_strict" {
  description = "Rate Limit für Login-Pfade. Trifft Bruteforce, nicht den normalen Betrieb - niemand meldet sich zwanzigmal pro Minute an."
  type = object({
    average = number
    burst   = number
    period  = string
  })
  default = {
    average = 10
    burst   = 5
    period  = "1m"
  }
}

variable "rate_limit_relaxed" {
  description = "Rate Limit für Sync-Pfade. Immich-Clients erzeugen im Hintergrund viele Requests; ein abbrechender Sync ist der teurere Fehler."
  type = object({
    average = number
    burst   = number
    period  = string
  })
  default = {
    average = 600
    burst   = 200
    period  = "1m"
  }
}

#
# ACME
#
variable "acme_email" {
  description = "Kontaktadresse für Let's Encrypt (Ablaufwarnungen)."
  type        = string
  default     = ""
}

variable "acme_ca_server" {
  description = "ACME-Verzeichnis. Für die ersten Läufe das Staging-Verzeichnis nehmen - das Produktionsverzeichnis hat harte Rate Limits."
  type        = string
  default     = "https://acme-v02.api.letsencrypt.org/directory"
}

variable "acme_dns_api_base" {
  description = <<-EOT
    Basis-URL der delegierten acme-dns-Instanz, z. B.
    "https://acme-dns.domain.de".

    Das ist der Kern von Entscheidung E4: Die Edge bekommt keinen Token des
    DNS-Anbieters, sondern Zugang zu genau ihren _acme-challenge-Records. Ein
    Zonen-Token wäre wertvoller als jedes Zertifikat auf dieser Maschine und
    würde ihr Neuausrollen überleben.

    Der lego-Provider liest diesen Wert ausschließlich aus der Umgebung; die
    systemd-Unit setzt ihn deshalb als ACME_DNS_API_BASE. Leer lassen heißt:
    kein Resolver `acmedns` und damit keine Zertifikate - sinnvoll nur,
    solange die acme-dns-Instanz noch nicht steht. Die Router laufen dann
    weiter, scheitern aber am sniStrict-Filter.

    Die Kontodaten selbst legt lego beim ersten Lauf unter
    /var/lib/traefik/acme-dns.json an und nennt dort die Subdomain, auf die
    der _acme-challenge-CNAME zeigen muss.
  EOT
  type        = string
  default     = ""
}

variable "acme_check_resolvers" {
  description = <<-EOT
    Resolver für die Propagationsprüfung der DNS-01-Challenge, ohne Portangabe.

    Leer lassen heißt: der interne Resolver. Das ist der Normalfall und
    entspricht dem Konzept ("DNS ausschließlich zum internen Resolver").
    Nachteil: Cacht er eine negative Antwort auf den TXT-Record, verzögert das
    die Ausstellung.

    Werden hier öffentliche Resolver eingetragen, öffnet der nftables-Regelsatz
    automatisch Port 53 zu genau diesen Adressen - eine bewusste, sichtbare
    Ausnahme.
  EOT
  type        = list(string)
  default     = []
}

#
# CrowdSec
#
variable "crowdsec_enabled" {
  description = "CrowdSec-Agent, AppSec und Firewall-Bouncer installieren. Die Dienste starten erst, wenn edge-crowdsec-connect die Zugangsdaten hinterlegt hat."
  type        = bool
  default     = true
}

variable "crowdsec_plugin_version" {
  description = "Version des Traefik-Plugins crowdsec-bouncer-traefik-plugin. Renovate verfolgt die Zeile in templates/traefik/traefik.yml.tftpl."
  type        = string
  default     = "v1.6.0"
}

variable "crowdsec_collections" {
  description = <<-EOT
    Hub-Collections für den Agenten auf der Edge. Zugeschnitten auf das, was
    hier tatsächlich anfällt: Proxy-Logs und SSH. Die App-Parser für Nextcloud
    und Immich gehören zusätzlich in den Cluster, wo die Anwendungslogs
    entstehen - ein fehlgeschlagener Nextcloud-Login liefert HTTP 200 und ist
    aus Proxy-Sicht nicht erkennbar.
  EOT
  type        = list(string)
  default = [
    "crowdsecurity/traefik",
    "crowdsecurity/http-cve",
    "crowdsecurity/base-http-scenarios",
    "crowdsecurity/http-dos",
    "crowdsecurity/whitelist-good-actors",
    "crowdsecurity/sshd",
    "crowdsecurity/linux",
    "crowdsecurity/appsec-virtual-patching",
    "crowdsecurity/appsec-generic-rules",
    "crowdsecurity/appsec-crs",
    "crowdsecurity/appsec-crs-exclusion-plugin-nextcloud",
  ]
}

variable "crowdsec_mode" {
  description = <<-EOT
    Betriebsmodus des Traefik-Plugins.
    stream - der Plugin-Cache hält die gesperrten IPs und aktualisiert sie
             regelmäßig. Damit hängt die Erreichbarkeit der öffentlichen
             Dienste nicht an der Erreichbarkeit des Clusters.
    live   - jede Anfrage einzeln gegen die LAPI. Genauer, aber jede Störung
             der DMZ-Strecke wird zur Störung der öffentlichen Dienste.
  EOT
  type        = string
  default     = "stream"

  validation {
    condition     = contains(["stream", "live", "none", "appsec"], var.crowdsec_mode)
    error_message = "crowdsec_mode muss stream, live, none oder appsec sein."
  }
}

variable "crowdsec_update_interval" {
  description = "Sekunden zwischen zwei Aktualisierungen der Sperrliste im stream-Modus."
  type        = number
  default     = 60
}

variable "crowdsec_log_level" {
  description = "Log-Level von Agent, Bouncer und Plugin."
  type        = string
  default     = "info"
}

variable "appsec_body_limit" {
  description = "Maximale Größe des Request-Bodys, den das Plugin an AppSec schickt. Darüber wird nur der Anfang geprüft - sonst liefe jeder große Upload durch die Payload-Inspektion."
  type        = number
  default     = 10485760
}

#
# Interne CA und mTLS
#
variable "step_cli_version" {
  description = "Version von step-cli (Client der internen CA)."
  type        = string
  default     = "0.30.6"
}

variable "step_cli_sha256" {
  description = "SHA256 von step-cli_<version>-1_amd64.deb. Quelle: https://github.com/smallstep/cli/releases"
  type        = string
  default     = "5845c181251ffe43ca2331bc171e0b92324a71be9cf4ef76cd6fbbba4f2a3cc6"
}

variable "step_ca_url" {
  description = "URL der internen CA im Cluster. Leer lassen, solange sie nicht steht - edge-mtls-bootstrap bricht dann mit einem Hinweis ab."
  type        = string
  default     = ""
}

variable "step_ca_fingerprint" {
  description = <<-EOT
    Fingerprint des Wurzelzertifikats der internen CA. Ohne ihn vertraut die
    Edge beim Bootstrap blind dem, was auf der CA-Adresse antwortet.
    Im Cluster ablesen: step certificate fingerprint $(step path)/certs/root_ca.crt
  EOT
  type        = string
  default     = ""
}

variable "step_ca_port" {
  description = "Port der internen CA. Dritte und letzte Öffnung von der DMZ nach innen; auf 0 setzen, wenn die CA über den Ingress-Port erreichbar ist."
  type        = number
  default     = 9000
}

variable "step_ca_ip" {
  description = "Adresse der internen CA im DMZ-Segment. Leer bedeutet: dieselbe wie cluster_ingress_ip."
  type        = string
  default     = ""
}

variable "cert_common_name" {
  description = "Common Name des Client-Zertifikats. Leer bedeutet <vm_name>.dmz."
  type        = string
  default     = ""
}

variable "cert_lifetime" {
  description = <<-EOT
    Laufzeit des Client-Zertifikats. 24 h ist Entscheidung E5: Eine
    cert-manager- oder step-ca-CA stellt keine CRL aus, und Traefiks clientAuth
    prüft ohnehin keine Revokation - kurze Laufzeit ersetzt den fehlenden
    Rückruf. Die CA muss diese Laufzeit erlauben (maxTLSCertDuration).
  EOT
  type        = string
  default     = "24h"
}

variable "cert_renew_before" {
  description = "Ab welcher Restlaufzeit erneuert wird. Der Timer prüft stündlich; der Abstand zur Gesamtlaufzeit ist der Puffer für fehlgeschlagene Versuche."
  type        = string
  default     = "8h"
}

variable "cluster_ingress_server_name" {
  description = "Erwarteter Name im Serverzertifikat von ingress-public. Muss zum SAN passen, nicht zur IP - sonst schlägt die Prüfung fehl und es bliebe nur insecureSkipVerify."
  type        = string
  default     = "ingress-public.internal"
}

variable "crowdsec_bouncer_armed" {
  description = <<-EOT
    Die CrowdSec-Middlewares in den Routern verwenden.

    Bewusst getrennt von crowdsec_enabled und standardmäßig aus: Das Plugin
    prüft beim Laden, ob die Key-Datei existiert, und verweigert sonst den
    Dienst - jeder Router, der es einbindet, wäre dann kaputt. Solange die LAPI
    im Cluster nicht steht, laufen die Router deshalb ohne Bouncer, mit
    Header-Hygiene, TLS und Rate Limiting.

    Ablauf: erst edge-crowdsec-connect auf der VM, dann hier auf true und
    `terraform apply`. Vorher zeigt vm/edge/verify/proxy-test.sh, ob die
    restliche Kette steht.
  EOT
  type        = bool
  default     = false
}

variable "entrypoint_sanitize_path" {
  description = <<-EOT
    Traefik normalisiert kodierte Zeichen im Pfad, bevor er weiterleitet.

    Für die Weboberflächen richtig so. Für WebDAV kann es stören: Nextcloud
    überträgt Dateinamen mit kodierten Sonderzeichen, und wenn Proxy und
    Anwendung den Pfad unterschiedlich lesen, entstehen schwer auffindbare
    Fehler beim Sync. Auf false wird der Pfad unverändert durchgereicht - dann
    aber prüfen, dass die WAF-Regeln und der Ingress dieselbe Sicht haben
    ("split view").
  EOT
  type        = bool
  default     = true
}

#
# UEFI-Firmware
#
# Standardmäßig sucht libvirt sich die Firmware selbst aus (`firmware = "efi"`
# plus die Feature-Angaben unten). Das funktioniert auf gängigen Distributionen
# - auf Unraid nicht: Dort liegt in /usr/share/qemu/firmware zwar ein
# Deskriptor 60-edk2-x86_64.json, der als NVRAM-Vorlage
# /usr/share/qemu/edk2-i386-vars.fd nennt, aber genau diese Datei liefert das
# Paket nicht mit. Der Start scheitert dann mit
#
#   Failed to open file '/usr/share/qemu/edk2-i386-vars.fd': No such file or directory
#
# Unraid bringt stattdessen sein eigenes OVMF mit, und seine VM-Oberfläche
# schreibt die Pfade explizit ins XML. Genau das machen diese beiden Variablen.
#
variable "efi_loader" {
  description = <<-EOT
    Pfad zum OVMF-Code (schreibgeschützt, pflash). Leer bedeutet: libvirt
    wählt die Firmware selbst aus.

    Auf Unraid: "/usr/share/qemu/ovmf-x64/OVMF_CODE-pure-efi.fd"
    Gegenprüfen mit: ls /usr/share/qemu/ovmf-x64/
  EOT
  type        = string
  default     = ""
}

variable "efi_vars_template" {
  description = <<-EOT
    Vorlage für den NVRAM-Speicher der Firmware. libvirt kopiert sie beim
    ersten Start nach nvram_dir. Muss zusammen mit efi_loader gesetzt werden.

    Auf Unraid: "/usr/share/qemu/ovmf-x64/OVMF_VARS-pure-efi.fd"
  EOT
  type        = string
  default     = ""

  validation {
    condition     = (var.efi_loader == "") == (var.efi_vars_template == "")
    error_message = "efi_loader und efi_vars_template gehören zusammen - entweder beide setzen oder beide leer lassen."
  }
}

variable "nvram_dir" {
  description = "Verzeichnis für den NVRAM-Speicher je VM. Nur relevant, wenn efi_loader gesetzt ist. Muss auf dem Hypervisor existieren und beschreibbar sein."
  type        = string
  default     = "/etc/libvirt/qemu/nvram"
}
