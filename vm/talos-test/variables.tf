#
# Cluster-Identität
#
variable "cluster_name" {
  description = "Name des Talos-Clusters. Wird auch für libvirt-Netzwerk und Domain verwendet."
  type        = string
  default     = "talos-test"
}

#
# Gepinnte Versionen - bewusst explizit, damit Renovate sie tracken kann
# und Test/Prod reproduzierbar bleiben.
#
variable "talos_version" {
  description = "Talos-Linux-Version. Releases: https://github.com/siderolabs/talos/releases"
  type        = string
  default     = "v1.13.7"
}

variable "kubernetes_version" {
  description = <<-EOT
    Kubernetes-Version im Cluster. Bewusst identisch zu kubectl_release_version
    in ansible/minikube-install.yml, damit Dev und Test dieselbe Version fahren.
    Talos v1.13.7 hat 1.36.2 als Default - Patches darüber sind unterstützt.
  EOT
  type        = string
  default     = "1.36.3"
}

#
# libvirt
#
variable "libvirt_uri" {
  description = "libvirt-Connection-URI. Lokal qemu:///system, auf Unraid später qemu+ssh://..."
  type        = string
  default     = "qemu:///system"
}

variable "libvirt_pool" {
  description = "Storage-Pool für ISO und System-Disk."
  type        = string
  default     = "default"
}

#
# Netzwerk
#
# Eigenes NAT-Netz statt des libvirt-"default"-Netzes: dessen DHCP-Range geht
# über das gesamte /24, damit lässt sich keine kollisionsfreie Reservierung
# anlegen. Die Reservierung ist nötig, weil der Node im Maintenance-Mode
# (vor der Installation) und danach dieselbe IP haben muss - sonst kennt
# Terraform die Adresse für apply-config nicht im Voraus.
#
variable "network_bridge" {
  description = "Name der Linux-Bridge für das Cluster-Netz (max. 15 Zeichen)."
  type        = string
  default     = "virbr-talos"
}

variable "network_gateway" {
  description = "Gateway-/Host-Adresse im Cluster-Netz."
  type        = string
  default     = "192.168.150.1"
}

variable "network_prefix" {
  description = "Präfixlänge des Cluster-Netzes."
  type        = number
  default     = 24
}

variable "dhcp_range" {
  description = "Dynamischer DHCP-Bereich. Muss die Node-IP ausschließen."
  type = object({
    start = string
    end   = string
  })
  default = {
    start = "192.168.150.100"
    end   = "192.168.150.199"
  }
}

variable "node_ip" {
  description = "Feste IP des Control-Plane-Nodes (DHCP-Reservierung, außerhalb von dhcp_range)."
  type        = string
  default     = "192.168.150.10"
}

variable "node_mac" {
  description = "MAC des Nodes. Muss im QEMU-Bereich 52:54:00 liegen und zur DHCP-Reservierung passen."
  type        = string
  default     = "52:54:00:7a:10:5c"
}

#
# VM-Dimensionierung
#
# 3 GB / 2 vCPU entspricht dem im Konzept vorgesehenen Test-Cluster auf Unraid.
# Lokal ist mehr RAM verfügbar - der Test soll aber die Zielgröße abbilden.
#
variable "vm_memory_mib" {
  description = "RAM der VM in MiB. Talos-Minimum für Control Plane: 2048."
  type        = number
  default     = 3072
}

variable "vm_vcpu" {
  description = "Anzahl vCPUs."
  type        = number
  default     = 2
}

variable "vm_disk_gib" {
  description = "Größe der System-Disk in GiB (qcow2, dünn alloziert)."
  type        = number
  default     = 20
}

variable "install_disk" {
  description = "Ziel-Device für die Talos-Installation innerhalb der VM."
  type        = string
  default     = "/dev/vda"
}

#
# Image
#
variable "system_extensions" {
  description = <<-EOT
    Offizielle Talos-System-Extensions, die in ISO und Installer-Image gebacken
    werden. Die daraus erzeugte Schematic-ID muss bei jedem Upgrade identisch
    sein, sonst verschwinden die Extensions - siehe k8s/Kubernetes-Prod-Konzept.md.
    Terraform hält sie deshalb im State.
  EOT
  type        = list(string)
  default     = ["siderolabs/qemu-guest-agent"]
}
