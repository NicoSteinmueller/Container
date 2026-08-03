#
# Cluster-Identität
#
variable "cluster_name" {
  description = "Name des Talos-Clusters. Geht in Node-, Volume- und Domainnamen ein."
  type        = string
  default     = "homelab"
}

variable "node_name" {
  description = "Hostname des Control-Plane-Nodes. Leer bedeutet <cluster_name>-cp1."
  type        = string
  default     = ""
}

#
# Gepinnte Versionen - bewusst explizit, damit Renovate sie verfolgen kann und
# ein Neuaufbau dieselbe Version ergibt wie der laufende Cluster.
#
variable "talos_version" {
  description = "Talos-Linux-Version. Releases: https://github.com/siderolabs/talos/releases"
  type        = string
  default     = "v1.13.7"
}

variable "kubernetes_version" {
  description = <<-EOT
    Kubernetes-Version im Cluster. Identisch zu vm/talos-test, damit Test und
    Produktion nicht auseinanderlaufen.
  EOT
  type        = string
  default     = "1.36.3"
}

variable "cilium_version" {
  description = <<-EOT
    Cilium-Chart-Version. Cilium wird als Inline-Manifest in die Machine-Config
    gerendert (siehe main.tf) - der Node ist damit direkt nach dem Bootstrap
    Ready, ohne zweiten Schritt von außen.
  EOT
  type        = string
  default     = "1.19.6"
}

variable "hubble_relay_enabled" {
  description = <<-EOT
    Hubble-Relay ausrollen. Standardmäßig aus, weil das RAM-Budget knapp ist -
    die VM startet mit 4 GB, solange die Dienste noch als Container auf dem
    Host laufen (siehe vm_memory_mib). Flows lassen sich auch ohne Relay
    ansehen:
      kubectl -n kube-system exec ds/cilium -- hubble observe --follow
  EOT
  type        = bool
  default     = false
}

variable "hubble_ui_enabled" {
  description = "Hubble-UI ausrollen. Braucht Relay und nochmals RAM; für einen einzelnen Node selten den Platz wert."
  type        = bool
  default     = false
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
    Name des Storage-Pools für ISO und System-Disk. Muss zu libvirt_pool in
    vm/edge passen - dort wird er angelegt, hier nur verwendet.
  EOT
  type        = string
  default     = "homelab"
}

variable "manage_pool" {
  description = <<-EOT
    Den Storage-Pool hier anlegen statt in vm/edge.

    Standardmäßig aus: Beide Module teilen sich denselben Pool, und ein
    libvirt-Objekt, das in zwei Terraform-States steht, ist eine Quelle für
    Ärger beim Zerstören. vm/edge läuft ohnehin zuerst - es legt auch das
    DMZ-Netz an.

    Nur einschalten, wenn dieses Modul allein betrieben wird (Laborlauf ohne
    Edge-VM).
  EOT
  type        = bool
  default     = false
}

variable "pool_path" {
  description = <<-EOT
    Verzeichnis des Pools, nur relevant bei manage_pool = true. Auf Unraid der
    Share `domains`, und zwar über /mnt/cache statt /mnt/user - siehe die
    ausführliche Begründung bei derselben Variable in vm/edge, wo der Pool
    tatsächlich angelegt wird. Kurz: /mnt/user ist eine FUSE-Schicht, und
    etcd fsyncnt zu oft, als dass die kostenlos wäre.

    Wird der Pool wie üblich von vm/edge verwaltet (manage_pool = false), hat
    dieser Wert hier keine Wirkung - dann zählt vm/edge/terraform.tfvars.
  EOT
  type        = string
  default     = "/mnt/cache/domains"

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
# LAN-Bein - Heimnetz hinter der Fritzbox
#
# Hier hängen: Talos-API, Kubernetes-API und ingress-internal. Nichts davon ist
# aus dem Internet erreichbar; die Fritzbox reicht ausschließlich 443 an die
# Edge-VM weiter, nicht hierher.
#
variable "lan_bridge" {
  description = <<-EOT
    Vorhandene Host-Bridge für das LAN-Bein (Unraid: "br0"). Auf null setzen,
    um stattdessen lan_libvirt_network zu verwenden - der Weg für einen lokalen
    Testlauf ohne Bridge.
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
  description = "Heimnetz. Quelle für Verwaltungszugriffe und für ingress-internal."
  type        = string
  default     = "192.168.178.0/24"

  validation {
    condition     = can(cidrhost(var.lan_cidr, 0))
    error_message = "lan_cidr muss ein CIDR sein, z. B. 192.168.178.0/24."
  }
}

variable "lan_ip" {
  description = <<-EOT
    Feste Adresse des Nodes im Heimnetz. Muss außerhalb des Fritzbox-DHCP-
    Bereichs liegen und darf nicht mit der Edge-VM kollidieren (dort .20).
    Diese Adresse ist zugleich der Kubernetes-API-Endpoint.
  EOT
  type        = string
  default     = "192.168.178.222"
}

variable "lan_gateway" {
  description = "Default-Gateway, in der Regel die Fritzbox. Einziges Gateway des Nodes - das DMZ-Bein bekommt bewusst keine Route."
  type        = string
  default     = "192.168.178.1"
}

variable "maintenance_link" {
  description = <<-EOT
    Interface-Name des LAN-Beins, wie der Kernel es beim Booten von der ISO
    benennt. Geht als `ip=`-Kernel-Parameter ins Image (siehe
    talos_image_factory_schematic in main.tf) und sorgt dafür, dass der Node
    schon im Maintenance-Mode unter lan_ip erreichbar ist - vorher gibt es dort
    nur DHCP, und der Config-Apply liefe ins Leere.

    Die Machine-Config selbst wählt das Interface über die MAC-Adresse, nicht
    über den Namen. Diese Variable ist nur für das Zeitfenster vor dem ersten
    Apply nötig, in dem es noch keine Config gibt, die eine MAC auswerten
    könnte.

    "enp1s0" ist der erste virtio-Adapter im q35-Layout dieses Moduls - für
    eine unveränderte Konfiguration also richtig. Gegenprüfen am laufenden
    Node im Maintenance-Mode:

      talosctl get links --insecure -n <dhcp-adresse> -e <dhcp-adresse>
  EOT
  type        = string
  default     = "enp1s0"
}

variable "dns_servers" {
  description = "Interner Resolver mit Query-Logging und Blocklist, wie in der Edge-VM."
  type        = list(string)
  default     = ["192.168.178.2"]

  validation {
    condition     = length(var.dns_servers) > 0
    error_message = "Mindestens ein Resolver nötig - ohne DNS kommt der Node an keine Images."
  }
}

variable "ntp_servers" {
  description = "NTP-Quellen. Ohne korrekte Zeit schlagen etcd, Kubelet-Zertifikate und die 24-h-Zertifikate der mTLS-Strecke fehl."
  type        = list(string)
  default     = ["192.168.178.1"]
}

#
# DMZ-Bein - die Strecke zur Edge-VM
#
# Das libvirt-Netz wird von vm/edge angelegt (isoliert, ohne Adresse auf dem
# Host, ohne DHCP). Dieses Modul hängt sich nur hinein - deshalb nur der Name
# und keine libvirt_network-Ressource.
#
variable "dmz_network_name" {
  description = "Name des von vm/edge angelegten libvirt-Netzes. Muss zu dmz_network_name dort passen."
  type        = string
  default     = "edge-dmz"
}

variable "dmz_cidr" {
  description = "Adressbereich der Strecke Edge -> Cluster. Muss zu vm/edge passen."
  type        = string
  default     = "10.10.20.0/29"

  validation {
    condition     = can(cidrhost(var.dmz_cidr, 0))
    error_message = "dmz_cidr muss ein CIDR sein, z. B. 10.10.20.0/29."
  }
}

variable "node_dmz_ip" {
  description = <<-EOT
    Adresse des Nodes im DMZ-Segment. Das ist die Adresse, die vm/edge als
    cluster_ingress_ip kennt: ingress-public, CrowdSec-LAPI und die interne CA
    hängen ausschließlich hier (hostPort mit hostIP, siehe k8s/platform).
  EOT
  type        = string
  default     = "10.10.20.3"
}

variable "edge_dmz_ip" {
  description = "Adresse der Edge-VM im DMZ-Segment. Einzige Quelle, die die exponierten Ports des Nodes erreichen darf."
  type        = string
  default     = "10.10.20.2"
}

variable "ingress_public_port" {
  description = "Port von ingress-public. Muss zu cluster_ingress_port in vm/edge passen."
  type        = number
  default     = 443
}

variable "crowdsec_lapi_port" {
  description = "Port der CrowdSec-LAPI. Muss zu crowdsec_lapi_port in vm/edge passen."
  type        = number
  default     = 8443
}

variable "step_ca_port" {
  description = "Port der internen CA. Muss zu step_ca_port in vm/edge passen."
  type        = number
  default     = 9000
}

variable "ingress_internal_ports" {
  description = "Ports von ingress-internal auf dem LAN-Bein. 80 nur für den Redirect auf 443."
  type        = list(number)
  default     = [80, 443]
}

#
# Zugang
#
variable "admin_sources" {
  description = <<-EOT
    Quelladressen, die Talos-API (50000) und Kubernetes-API (6443) erreichen
    dürfen. Eng fassen: Wer hier hineinkommt, hat den Cluster.

    Achtung: Ein Fehler hier sperrt die Verwaltung aus. Der Notzugang ist die
    serielle Konsole (virsh console) plus `talosctl apply-config` über die
    Maintenance-API - siehe README.
  EOT
  type        = list(string)
  default     = ["192.168.178.0/24"]

  validation {
    condition     = length(var.admin_sources) > 0
    error_message = "Ohne Quelladresse gäbe es keinen Verwaltungszugang mehr."
  }
}

variable "kubelet_server_certs" {
  description = <<-EOT
    Das Kubelet lässt sich sein Serverzertifikat über einen CSR ausstellen
    (serverTLSBootstrap), statt sich eines selbst zu unterschreiben.

    Braucht einen Genehmiger im Cluster - kubelet-csr-approver, den
    k8s/platform mitbringt. Ohne ihn bleibt der Antrag auf "Pending",
    `kubectl logs` und `kubectl exec` funktionieren nicht mehr, und
    `data.talos_cluster_health` bricht den Lauf ab mit:

      kubelet server certificate rotation is enabled, but CSR is not approved

    Deshalb ein Schalter und keine feste Zeile in patches/hardening.yaml:
    Beim ersten Aufbau kommt der Node vor dem Cluster, der Genehmiger aber
    erst mit k8s/platform. Reihenfolge:

      1. vm/talos      terraform apply                    (false)
      2. k8s/platform  terraform apply                    bringt den Genehmiger
      3. vm/talos      kubelet_server_certs = true, apply
      4.               talosctl -n <lan_ip> reboot
      5. k8s/platform  metrics_server_enabled = true, apply

    Wofür man es will: Ohne echte Kubelet-Zertifikate braucht metrics-server
    --kubelet-insecure-tls - eine ungeprüfte Verbindung zu der Komponente,
    die Auskunft über jeden Pod auf dem Node gibt. Ausführlich in
    patches/kubelet-server-certs.yaml.
  EOT
  type        = bool
  default     = false
}

variable "ingress_firewall_enforced" {
  description = <<-EOT
    Talos-Ingress-Firewall auf "block" stellen (Zielzustand).

    true  - eingehend ist auf dem Node nur erlaubt, was in patches/
            ingress-firewall.yaml.tftpl steht: Verwaltung aus admin_sources,
            die drei DMZ-Ports von der Edge-VM, ingress-internal aus dem LAN,
            Kubelet und API aus dem Cluster selbst.
    false - Regeln werden trotzdem geschrieben, die Default-Aktion bleibt aber
            "accept". Nur für die Inbetriebnahme.

    Gegenprobe: `talosctl -n <lan_ip> get nodeportconfig` bzw. ein
    Verbindungsversuch aus einer nicht gelisteten Quelle (verify/assert-cluster.sh).
  EOT
  type        = bool
  default     = true
}

#
# VM-Dimensionierung
#
# Das Ressourcenkapitel des Konzepts nennt "Talos-VM 10 GB" - das ist der
# Endausbau, nicht der Startwert. Solange Nextcloud, Immich und Paperless noch
# als Docker-Container auf dem Host laufen, ist deren Speicher schlicht nicht
# frei: 16 GB Host, davon rund 7,5 GB Container und 1,5 GB Edge-VM. Eine
# 10-GB-VM startet dort nicht.
#
# Der Startwert war zunächst 4096, hergeleitet aus "16 - 7,5 - 1,5 = rund 5 GB
# übrig". Diese Rechnung ist falsch aufgestellt, und der Fehler ist lehrreich:
# Sie unterstellt, dass freier Speicher der VM zusteht. Der Host braucht davon
# aber selbst Page-Cache, und Unraid hat ab Werk keinen Swap. Gemessen blieben
# bei 4 GB noch 629 MB frei; ab da lief kswapd0 dauerhaft und warf Page-Cache
# weg - darunter den Kernel-Modul-Squashfs /boot/bzmodules, dessen
# Backing-Store der USB-Boot-Stick ist. Der stand bei 74 % Auslastung, und der
# ganze Host lief in 70 % iowait bei 6 % User-CPU. Load 15,7, ohne dass
# irgendetwas gerechnet hätte.
#
# Der zweite Anlauf mit 3072 war ebenfalls zu klein, und diesmal lag der Fehler
# nicht am Host, sondern an der Annahme, der Plattform-Stack sei "fast nichts".
# Gemessen im laufenden Cluster, noch ohne jede Nutzlast:
#
#   Memory-Requests der Pods   1900 MiB
#   Node-Gesamt (Talos)        2880 MiB   (von 3072 MiB VM)
#   dazu Talos, kubelet, CRI   ~600 MiB
#
# Talos' runtime.OOMController hat daraufhin reihenweise Cgroups abgeschossen;
# sichtbar wurde das als Probe-Timeouts bei Cilium, CoreDNS, cert-manager und
# kube-controller-manager - also überall, nur nicht dort, wo die Ursache lag.
# Die größten Posten sind kube-apiserver (512 Mi), controller-manager und
# Cilium (je 256 Mi), Kyverno über vier Controller (320 Mi) und CrowdSec
# (256 Mi).
#
# 5 GB tragen den leeren Cluster mit dem vollen Plattform-Stack und lassen
# echten Puffer. Wichtig für den Fahrplan unten: Der Stack muss passen, BEVOR
# der erste Dienst migriert - "klein anfangen und pro Dienst wachsen" gilt erst
# ab hier, nicht schon für die Grundausstattung.
#
# Der Wert ist nicht ForceNew, ein `terraform apply` schreibt nur die
# Domain-Definition neu:
#
#   # libvirt_domain.talos will be updated in-place
#     ~ memory = 5120 -> 6144
#
# libvirt übernimmt das in die persistente Konfiguration; wirksam wird es beim
# nächsten Start der VM (Talos: `talosctl -n <lan_ip> shutdown`, dann
# `virsh start homelab-cp1`). Faustregel für den Fahrplan: pro migriertem
# Dienst erst den Container auf dem Host stoppen, dann den RAM nachziehen -
# nicht umgekehrt, sonst konkurrieren beide um dieselben Seiten.
#
# Kontrolle vor jeder Erhöhung, auf dem Host: `free -m`. Bleibt "available"
# unter etwa 1,5 GB, ist der nächste Schritt keine Erhöhung, sondern das
# Abschalten eines Containers.
#
variable "vm_memory_mib" {
  description = "RAM der VM in MiB. Startwert für den leeren Cluster; mit jedem migrierten Dienst erhöhen (In-Place-Update, VM-Neustart nötig)."
  type        = number
  default     = 5120
}

variable "wait_for_health" {
  description = <<-EOT
    Nach dem Bootstrap warten, bis Control Plane und Node gesund sind.

    Im Normalbetrieb an lassen: Ohne diesen Check meldet `terraform apply`
    auch dann Erfolg, wenn der Node NotReady bleibt.

    Auf false setzen für zwei Fälle, beide unangenehm:

      - `terraform destroy`, wenn die VM schon aus ist. Data Sources werden
        vor jedem Plan gelesen, auch beim Zerstören - der Check läuft sonst
        erst in seinen 20-Minuten-Timeout.
      - Reparaturläufe. Ist der Cluster kaputt, blockiert der Check genau das
        `apply`, das den Fehler beheben würde.

    In beiden Fällen als Flag mitgeben statt in die tfvars zu schreiben:

      terraform destroy -var wait_for_health=false
  EOT
  type        = bool
  default     = true
}

variable "vm_vcpu" {
  description = "Anzahl vCPUs. Konzept: 4-6."
  type        = number
  default     = 4
}

variable "vm_disk_gib" {
  description = "Größe der System-Disk in GiB (qcow2, dünn alloziert). Enthält auch die local-path-PVCs (Postgres) - Nutzerdaten gehören später auf das Unraid-Array."
  type        = number
  default     = 100
}

variable "install_disk" {
  description = "Ziel-Device für die Talos-Installation innerhalb der VM."
  type        = string
  default     = "/dev/vda"
}

variable "mac_lan" {
  description = "MAC des LAN-Beins. Muss im QEMU-Bereich 52:54:00 liegen."
  type        = string
  default     = "52:54:00:7a:20:01"
}

variable "mac_dmz" {
  description = "MAC des DMZ-Beins. Muss im QEMU-Bereich 52:54:00 liegen."
  type        = string
  default     = "52:54:00:7a:20:02"
}

variable "system_extensions" {
  description = <<-EOT
    Offizielle Talos-System-Extensions für ISO und Installer-Image. Die daraus
    erzeugte Schematic-ID muss bei jedem Upgrade identisch sein, sonst
    verschwinden die Extensions.
  EOT
  type        = list(string)
  default     = ["siderolabs/qemu-guest-agent"]
}

#
# Cluster-Netz
#
variable "pod_subnet" {
  description = "Pod-CIDR. Darf sich mit nichts im Heimnetz und in der DMZ überschneiden."
  type        = string
  default     = "10.244.0.0/16"
}

variable "service_subnet" {
  description = "Service-CIDR."
  type        = string
  default     = "10.96.0.0/12"
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
