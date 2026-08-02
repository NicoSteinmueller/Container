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
    Hubble-Relay ausrollen. Standardmäßig aus, weil das RAM-Budget knapp ist
    (Konzept: 10 GB für die gesamte Talos-VM). Flows lassen sich auch ohne
    Relay ansehen:
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
  description = "Storage-Pool für ISO und System-Disk."
  type        = string
  default     = "default"
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
  default     = "192.168.178.21"
}

variable "lan_gateway" {
  description = "Default-Gateway, in der Regel die Fritzbox. Einziges Gateway des Nodes - das DMZ-Bein bekommt bewusst keine Route."
  type        = string
  default     = "192.168.178.1"
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
# 10 GB entspricht der Zeile "Talos-VM 10 GB" aus dem Ressourcenkapitel des
# Konzepts: rund 2 GB Cluster-Overhead, der Rest für Nextcloud mit Postgres,
# Immich und Paperless.
#
variable "vm_memory_mib" {
  description = "RAM der VM in MiB."
  type        = number
  default     = 10240
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
