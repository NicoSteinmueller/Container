#
# Identität
#
variable "vm_name" {
  description = "Name der libvirt-Domain und Hostname der VM."
  type        = string
  default     = "fw1"
}

variable "timezone" {
  description = "Zeitzone der VM. Wirkt auf die Zeitstempel der Deny-Logs."
  type        = string
  default     = "Europe/Berlin"
}

#
# Alpine
#
# Version bewusst voll gepinnt, damit Renovate sie tracken kann (renovate.json5,
# customManagers). Der Branch (v3.24) wird daraus abgeleitet.
#
variable "alpine_version" {
  description = "Alpine-Release. Releases: https://alpinelinux.org/releases/"
  type        = string
  default     = "3.24.1"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.alpine_version))
    error_message = "alpine_version muss die Form MAJOR.MINOR.PATCH haben, z. B. 3.24.1."
  }
}

variable "alpine_image_revision" {
  description = "Revision des Cloud-Images (Suffix -rN im Dateinamen)."
  type        = string
  default     = "r0"
}

#
# libvirt
#
variable "libvirt_uri" {
  description = "libvirt-Connection-URI. Lokal qemu:///system, auf Unraid qemu+ssh://root@unraid/system."
  type        = string
  default     = "qemu:///system"
}

variable "libvirt_pool" {
  description = "Storage-Pool für Basis-Image, System-Disk und Cloud-Init-ISO."
  type        = string
  default     = "default"
}

#
# WAN - die Seite zur Fritzbox
#
# Die Firewall hängt mit einem Bein im Heimnetz. Von dort kommt sowohl der per
# Portfreigabe weitergereichte Internet-Verkehr als auch der LAN-Verkehr - der
# Regelsatz unterscheidet die beiden über die Ziel-/Quelladresse, nicht über das
# Interface (siehe templates/nftables.nft.tftpl).
#
variable "wan_bridge" {
  description = <<-EOT
    Vorhandene Host-Bridge für das WAN-Bein (Unraid: "br0"). Vor dem ersten
    Apply mit `ip -br link` auf dem Hypervisor gegenprüfen. Wird hier null
    gesetzt, greift stattdessen wan_libvirt_network - nützlich für lokale Tests.
  EOT
  type        = string
  default     = "br0"
}

variable "wan_libvirt_network" {
  description = "Name eines vorhandenen libvirt-Netzes für das WAN-Bein. Nur wirksam, wenn wan_bridge = null."
  type        = string
  default     = "default"
}

variable "wan_ip" {
  description = <<-EOT
    Feste IP der Firewall im Heimnetz. Ziel der Fritzbox-Portfreigabe
    (443 tcp+udp) und der Split-DNS-Einträge in AdGuard. Muss außerhalb des
    DHCP-Bereichs der Fritzbox liegen oder dort reserviert sein.
  EOT
  type        = string
  default     = "192.168.178.6"
}

variable "wan_prefix" {
  description = "Präfixlänge des Heimnetzes."
  type        = number
  default     = 24
}

variable "wan_gateway" {
  description = "Default-Gateway der Firewall (Fritzbox)."
  type        = string
  default     = "192.168.178.1"
}

variable "lan_cidr" {
  description = "Heimnetz. Aus DMZ und Cluster-Netz ist dieser Bereich verboten - der Kern der Segmentierung."
  type        = string
  default     = "192.168.178.0/24"

  validation {
    condition     = can(cidrnetmask(var.lan_cidr))
    error_message = "lan_cidr muss ein gültiges IPv4-CIDR sein."
  }
}

variable "dns_servers" {
  description = "Resolver für die Firewall selbst (apk, NTP-Namensauflösung)."
  type        = list(string)
  default     = ["192.168.178.1"]
}

#
# Management - der einzige Weg auf die VM
#
# Isoliertes libvirt-Netz: Der Hypervisor-Host hat dort eine Adresse, sonst
# niemand. SSH ist ausschließlich hierauf gebunden, nie auf WAN oder DMZ
# (k8s/Edge-Architektur.md, Abschnitt 5). Zugriff aus dem LAN läuft damit
# zwingend über den Host als Sprungbrett.
#
variable "mgmt_network_name" {
  description = "Name des libvirt-Management-Netzes."
  type        = string
  default     = "fw-mgmt"
}

variable "mgmt_bridge" {
  description = "Bridge-Name des Management-Netzes (max. 15 Zeichen)."
  type        = string
  default     = "virbr-fwmgmt"
}

variable "mgmt_cidr" {
  description = "Management-Netz."
  type        = string
  default     = "10.10.10.0/24"
}

variable "mgmt_host_ip" {
  description = "Adresse des Hypervisor-Hosts im Management-Netz."
  type        = string
  default     = "10.10.10.1"
}

variable "mgmt_ip" {
  description = "Adresse der Firewall im Management-Netz. Ziel für SSH."
  type        = string
  default     = "10.10.10.2"
}

#
# DMZ - Segment der Edge-VM
#
# Reines L2-Netz ohne Adresse auf dem Host und ohne dnsmasq: Der Hypervisor soll
# kein Bein in der DMZ haben, und Default-Gateway ist die Firewall, nicht libvirt.
# Gäste in diesem Segment werden deshalb statisch adressiert.
#
variable "dmz_network_name" {
  description = "Name des libvirt-DMZ-Netzes."
  type        = string
  default     = "fw-dmz"
}

variable "dmz_bridge" {
  description = "Bridge-Name des DMZ-Netzes (max. 15 Zeichen)."
  type        = string
  default     = "virbr-dmz"
}

variable "dmz_cidr" {
  description = "DMZ-Segment."
  type        = string
  default     = "10.10.20.0/24"
}

variable "dmz_gateway_ip" {
  description = "Adresse der Firewall in der DMZ - Default-Gateway der Edge-VM."
  type        = string
  default     = "10.10.20.1"
}

variable "edge_ip" {
  description = "Feste Adresse der Edge-VM (Traefik + CrowdSec). Ziel des DNAT für 443."
  type        = string
  default     = "10.10.20.10"
}

#
# Cluster - Segment der Talos-VMs
#
variable "cluster_network_name" {
  description = "Name des libvirt-Cluster-Netzes."
  type        = string
  default     = "fw-cluster"
}

variable "cluster_bridge" {
  description = "Bridge-Name des Cluster-Netzes (max. 15 Zeichen)."
  type        = string
  default     = "virbr-cluster"
}

variable "cluster_cidr" {
  description = "Cluster-Segment."
  type        = string
  default     = "10.10.30.0/24"
}

variable "cluster_gateway_ip" {
  description = "Adresse der Firewall im Cluster-Netz - Default-Gateway der Talos-Nodes."
  type        = string
  default     = "10.10.30.1"
}

variable "cluster_ingress_ip" {
  description = "LoadBalancer-IP des Cluster-Ingress (Cilium LB-IPAM). Einziges erlaubtes Ziel aus der DMZ."
  type        = string
  default     = "10.10.30.100"
}

#
# MAC-Adressen
#
# Fest vergeben, weil die VM ihre Interfaces darüber zuordnet: Cloud-Init
# adressiert per MAC-Match, und fw-render-interfaces löst dieselben MACs zur
# Laufzeit in Interface-Namen für nftables auf. Damit hängt nichts an der
# Reihenfolge, in der der Kernel eth0..eth3 vergibt.
#
variable "mac_wan" {
  description = "MAC des WAN-Interfaces (QEMU-Bereich 52:54:00)."
  type        = string
  default     = "52:54:00:f1:00:01"
}

variable "mac_mgmt" {
  description = "MAC des Management-Interfaces."
  type        = string
  default     = "52:54:00:f1:00:02"
}

variable "mac_dmz" {
  description = "MAC des DMZ-Interfaces."
  type        = string
  default     = "52:54:00:f1:00:03"
}

variable "mac_cluster" {
  description = "MAC des Cluster-Interfaces."
  type        = string
  default     = "52:54:00:f1:00:04"
}

#
# VM-Dimensionierung
#
variable "vm_memory_mib" {
  description = "RAM in MiB. Alpine + nftables kommt mit 256 aus; 512 lässt Luft für Logs und tcpdump."
  type        = number
  default     = 512
}

variable "vm_vcpu" {
  description = "Anzahl vCPUs."
  type        = number
  default     = 1
}

variable "vm_disk_gib" {
  description = "Größe der System-Disk in GiB (qcow2, dünn alloziert, wird beim ersten Boot aufgezogen)."
  type        = number
  default     = 4
}

#
# Zugang
#
variable "ssh_authorized_keys" {
  description = "Öffentliche SSH-Schlüssel für den Admin-Benutzer. Ohne diese gibt es keinen Weg auf die VM - Passwort-Login ist deaktiviert."
  type        = list(string)

  validation {
    condition     = length(var.ssh_authorized_keys) > 0
    error_message = "Mindestens ein SSH-Public-Key ist erforderlich."
  }
}

variable "admin_user" {
  description = "Benutzername für den SSH-Zugang. root-Login ist abgeschaltet."
  type        = string
  default     = "fwadmin"
}

#
# Regelsatz-Optionen
#
variable "admin_sources" {
  description = <<-EOT
    LAN-Adressen bzw. -Netze, die auf die Cluster-Admin-Ports (kube-apiserver,
    talosctl) zugreifen dürfen. Leer lassen, solange der Zugriff über WireGuard
    läuft - so sieht es das Konzept vor (Kapitel 4).
  EOT
  type        = list(string)
  default     = []
}

variable "cluster_admin_ports" {
  description = "TCP-Ports für admin_sources: kube-apiserver und Talos-API."
  type        = list(number)
  default     = [6443, 50000]
}

variable "egress_tcp_ports" {
  description = "Ausgehend erlaubte TCP-Ports aus DMZ und Cluster (ACME, CrowdSec-LAPI, Image-Pulls)."
  type        = list(number)
  default     = [53, 80, 443]
}

variable "egress_udp_ports" {
  description = "Ausgehend erlaubte UDP-Ports aus DMZ und Cluster (DNS, NTP, QUIC)."
  type        = list(number)
  default     = [53, 123, 443]
}

variable "extra_forward_rules" {
  description = <<-EOT
    Zusätzliche nft-Regeln, die unverändert ans Ende der forward-Chain gehängt
    werden - Notausgang für Fälle, die die obigen Variablen nicht abdecken.
    Verfügbare Variablen: $wan_if, $mgmt_if, $dmz_if, $clu_if, $lan_net,
    $mgmt_net, $dmz_net, $clu_net, $edge_ip, $ingress_ip, $wan_ip.
  EOT
  type        = list(string)
  default     = []
}

#
# Betrieb
#
variable "syslog_remote" {
  description = <<-EOT
    Ziel für Remote-Syslog im Format HOST:PORT, z. B. "192.168.178.4:1514" für
    den bestehenden Loki-Stack. null = nur lokal nach /var/log/messages.
    Die Deny-Regeln loggen unabhängig davon.
  EOT
  type        = string
  default     = null
}

variable "auto_upgrade" {
  description = "Wöchentliches `apk upgrade` per crond (k8s/CI-CD-Konzept.md, Abschnitt 5). Kernel-Updates werden erst nach einem Reboot wirksam."
  type        = bool
  default     = true
}

variable "extra_packages" {
  description = "Zusätzliche apk-Pakete. Achtung: `openssh` nicht hinzufügen, das Cloud-Image enthält bereits openssh-server-pam."
  type        = list(string)
  default     = []
}
