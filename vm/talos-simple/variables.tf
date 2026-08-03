#
# Cluster-Identität
#
variable "cluster_name" {
  description = "Name des Clusters. Geht in Node-, Volume- und Domainnamen ein."
  type        = string
  default     = "talos"
}

#
# Versionen - explizit gepinnt, damit ein Neuaufbau dieselbe Version ergibt
# wie der laufende Cluster.
#
variable "talos_version" {
  description = "Talos-Linux-Version. Releases: https://github.com/siderolabs/talos/releases"
  type        = string
  default     = "v1.13.7"
}

variable "kubernetes_version" {
  description = "Kubernetes-Version im Cluster."
  type        = string
  default     = "1.36.3"
}

variable "system_extensions" {
  description = <<-EOT
    Offizielle Talos-System-Extensions für ISO und Installer-Image. Die daraus
    erzeugte Schematic-ID muss bei jedem Upgrade dieselbe sein, sonst
    verschwinden die Extensions - deshalb hält Terraform sie im State.

    qemu-guest-agent ist das Gegenstück zum Channel in der Domain und
    ermöglicht libvirt ein sauberes Herunterfahren.
  EOT
  type        = list(string)
  default     = ["siderolabs/qemu-guest-agent"]
}

#
# libvirt
#
variable "libvirt_uri" {
  description = <<-EOT
    libvirt-Connection-URI.

    Ohne diese Angabe läuft alles gegen den libvirt der eigenen Arbeitsstation
    statt gegen Unraid. Für Unraid: qemu+ssh://root@<host>/system
  EOT
  type        = string
  default     = "qemu:///system"
}

variable "libvirt_pool" {
  description = "Storage-Pool für ISO und System-Disk. Auf Unraid existiert `homelab` bereits (angelegt von vm/edge)."
  type        = string
  default     = "homelab"
}

variable "manage_pool" {
  description = <<-EOT
    Den Pool hier anlegen statt einen vorhandenen zu benutzen.

    Standardmäßig aus: Auf Unraid gehört der Pool `homelab` zu vm/edge, und ein
    libvirt-Objekt in zwei Terraform-States ist eine Fehlerquelle beim
    Zerstören. Nur einschalten, wenn dieses Modul allein läuft.
  EOT
  type        = bool
  default     = false
}

variable "pool_path" {
  description = <<-EOT
    Verzeichnis des Pools, nur relevant bei manage_pool = true. Auf Unraid der
    Share `domains` über /mnt/cache statt /mnt/user: derselbe Ort, aber ohne
    die shfs-FUSE-Schicht. Über /mnt/user läuft jeder Blockzugriff der VM durch
    einen Userspace-Daemon, und etcd fsyncnt zu oft, als dass das kostenlos wäre.
  EOT
  type        = string
  default     = "/mnt/cache/domains"

  #
  # Kreuzprobe gegen den häufigsten Fehlgriff: Unraid-Pfad, aber lokaler
  # Hypervisor. Ohne die Prüfung legt Terraform den Pool klaglos auf der
  # Arbeitsstation an, und der Fehler fällt erst auf, wenn die VM nicht startet.
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
# Netzanbindung
#
# Drei Wege, in dieser Reihenfolge ausgewertet:
#
#   macvtap  - lan_macvtap_dev gesetzt. Für Unraid-Hosts ohne Bridging; dort
#              gibt es kein br0, sondern nur bond0/ethX.
#   Bridge   - lan_bridge gesetzt (Unraid mit Bridging: br0).
#   libvirt  - keins von beidem: vorhandenes libvirt-Netz, lokaler Test.
#
variable "lan_macvtap_dev" {
  description = <<-EOT
    Physisches Interface für ein macvtap-Bein. Auf diesem Unraid-Host ist
    Bridging abgeschaltet (`ip -br link` zeigt bond0 und vhost0, kein br0),
    deshalb "bond0".

    Was macvtap bedeutet, und das ist kein Detail: Die VM erreicht das LAN und
    das LAN erreicht die VM - aber die VM und der Unraid-Host selbst sehen
    einander nicht. Von der Arbeitsstation aus ist der Node also erreichbar,
    von einer SSH-Sitzung auf Unraid nicht. Docker-Container in einem
    macvlan-Netz auf demselben Parent sind dagegen erreichbar.
  EOT
  type        = string
  default     = null
}

variable "lan_bridge" {
  description = "Vorhandene Host-Bridge, wenn lan_macvtap_dev nicht gesetzt ist (Unraid mit Bridging: \"br0\")."
  type        = string
  default     = null
}

variable "lan_libvirt_network" {
  description = "Vorhandenes libvirt-Netz, wenn weder macvtap noch Bridge gesetzt sind (lokaler Test: \"default\")."
  type        = string
  default     = "default"
}

variable "lan_cidr" {
  description = "Heimnetz, in dem der Node steht."
  type        = string
  default     = "192.168.178.0/24"

  validation {
    condition     = can(cidrhost(var.lan_cidr, 0))
    error_message = "lan_cidr muss ein CIDR sein, z. B. 192.168.178.0/24."
  }
}

variable "lan_ip" {
  description = <<-EOT
    Feste Adresse des Nodes. Muss außerhalb des DHCP-Bereichs der Fritzbox
    liegen und darf mit nichts anderem im Netz kollidieren.

    Diese Adresse ist zugleich der Kubernetes-API-Endpoint und das Ziel für
    talosctl - sie steht deshalb auch in kubeconfig und talosconfig.
  EOT
  type        = string
  default     = "192.168.178.230"
}

variable "lan_gateway" {
  description = "Default-Gateway, in der Regel die Fritzbox."
  type        = string
  default     = "192.168.178.1"
}

variable "dns_servers" {
  description = <<-EOT
    Resolver des Nodes. Ohne DNS kommt er an keine Container-Images.

    Default ist bewusst die Fritzbox und nicht der AdGuard-Container: ein
    Baustein weniger, der beim ersten Aufbau kaputt sein kann. Auf den internen
    Resolver umstellen, sobald der Cluster steht.
  EOT
  type        = list(string)
  default     = ["192.168.178.1"]

  validation {
    condition     = length(var.dns_servers) > 0
    error_message = "Mindestens ein Resolver nötig - ohne DNS kommt der Node an keine Images."
  }
}

variable "ntp_servers" {
  description = "NTP-Quellen. Ohne korrekte Zeit schlagen etcd und die Zertifikatsprüfungen des Kubelets fehl."
  type        = list(string)
  default     = ["192.168.178.1"]
}

variable "node_mac" {
  description = "MAC des Nodes. Muss im QEMU-Bereich 52:54:00 liegen. Dieselbe MAC wählt in der Machine-Config das Interface aus."
  type        = string
  default     = "52:54:00:7a:30:01"
}

variable "maintenance_link" {
  description = <<-EOT
    Interface-Name, wie der Kernel das Bein beim Booten von der ISO benennt.

    Geht als `ip=`-Kernel-Parameter ins Image und sorgt dafür, dass der Node
    schon im Maintenance-Mode unter lan_ip erreichbar ist - vorher gäbe es dort
    nur DHCP, und der Config-Apply liefe ins Leere.

    Die Machine-Config selbst wählt das Interface später über die MAC, nicht
    über den Namen. Diese Variable gilt nur für das Zeitfenster davor.

    "enp1s0" ist der erste virtio-Adapter im q35-Layout dieses Moduls.
    Gegenprüfen am Node im Maintenance-Mode:
      talosctl get links --insecure -n <adresse> -e <adresse>
  EOT
  type        = string
  default     = "enp1s0"
}

#
# Cluster-Netz
#
variable "pod_subnet" {
  description = "Pod-CIDR. Darf sich mit nichts im Heimnetz überschneiden."
  type        = string
  default     = "10.244.0.0/16"
}

variable "service_subnet" {
  description = "Service-CIDR."
  type        = string
  default     = "10.96.0.0/12"
}

#
# VM-Dimensionierung
#
variable "vm_memory_mib" {
  description = <<-EOT
    RAM der VM in MiB.

    4096 trägt einen leeren Cluster mit Flannel und CoreDNS bequem. Der Host
    hat rund 7 GB `available`, während Nextcloud, Immich und Paperless noch als
    Container laufen - vor jeder Erhöhung dort gegenprüfen:

      ssh root@<unraid> free -m

    Maßgeblich ist die Spalte `available`, nicht `free`. Bleibt sie unter etwa
    1,5 GB, ist der nächste Schritt keine Erhöhung, sondern das Abschalten
    eines Containers. Unraid hat ab Werk keinen Swap.

    `memory` ist kein ForceNew-Feld: Ein Apply schreibt nur die
    Domain-Definition neu, wirksam wird der Wert beim nächsten Start der VM.
  EOT
  type        = number
  default     = 4096
}

variable "vm_vcpu" {
  description = "Anzahl vCPUs."
  type        = number
  default     = 4
}

variable "vm_disk_gib" {
  description = <<-EOT
    Größe der System-Disk in GiB. qcow2 ist dünn alloziert, der Platz wird also
    nicht sofort belegt. Großzügig wählen: Die Kapazität nachträglich zu ändern,
    ersetzt das Volume und damit den Cluster.
  EOT
  type        = number
  default     = 100
}

variable "install_disk" {
  description = "Ziel-Device für die Talos-Installation innerhalb der VM."
  type        = string
  default     = "/dev/vda"
}

#
# UEFI-Firmware
#
# Standardmäßig sucht libvirt sich die Firmware selbst aus. Das funktioniert auf
# gängigen Distributionen - auf Unraid nicht: Dort nennt der mitgelieferte
# Deskriptor 60-edk2-x86_64.json als NVRAM-Vorlage /usr/share/qemu/edk2-i386-vars.fd,
# und genau diese Datei liefert das Paket nicht mit. Der Start scheitert dann mit
#
#   Failed to open file '/usr/share/qemu/edk2-i386-vars.fd': No such file or directory
#
# Unraid bringt stattdessen sein eigenes OVMF mit - diese beiden Variablen
# schreiben die Pfade explizit ins Domain-XML, so wie es Unraids VM-Oberfläche
# auch tut.
#
variable "efi_loader" {
  description = <<-EOT
    Pfad zum OVMF-Code (schreibgeschützt, pflash). Leer bedeutet: libvirt wählt
    die Firmware selbst aus.

    Auf Unraid: "/usr/share/qemu/ovmf-x64/OVMF_CODE-pure-efi.fd"
  EOT
  type        = string
  default     = ""
}

variable "efi_vars_template" {
  description = <<-EOT
    Vorlage für den NVRAM-Speicher der Firmware. libvirt kopiert sie beim ersten
    Start nach nvram_dir.

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
  description = "Verzeichnis für den NVRAM-Speicher je VM. Nur relevant, wenn efi_loader gesetzt ist. Muss auf dem Hypervisor existieren."
  type        = string
  default     = "/etc/libvirt/qemu/nvram"
}

#
# Ablauf
#
variable "wait_for_health" {
  description = <<-EOT
    Nach dem Bootstrap warten, bis Control Plane und Node gesund sind.

    Im Normalbetrieb an lassen: Ohne den Check meldet `terraform apply` auch
    dann Erfolg, wenn der Node NotReady bleibt.

    Auf false setzen für zwei Fälle, beide unangenehm:

      - `terraform destroy`, wenn die VM schon aus ist. Data Sources werden vor
        jedem Plan gelesen, auch beim Zerstören - der Check läuft sonst erst in
        seinen 20-Minuten-Timeout.
      - Reparaturläufe. Ist der Cluster kaputt, blockiert derselbe Check genau
        das `apply`, das den Fehler beheben würde.

    In beiden Fällen als Flag mitgeben statt in die tfvars zu schreiben:

      terraform destroy -var wait_for_health=false
  EOT
  type        = bool
  default     = true
}
