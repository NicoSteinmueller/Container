#
# Cluster-Identität
#
variable "cluster_name" {
  description = "Name des Clusters. Geht in Node-, Volume- und Domainnamen ein."
  type        = string
  default     = "talos"
}

#
# Versionen - gepinnt, damit ein Neuaufbau dieselbe Version ergibt wie der
# laufende Cluster.
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

variable "cilium_version" {
  description = <<-EOT
    Cilium-Chart-Version. Cilium wird als Inline-Manifest in die Machine-Config
    gerendert (siehe main.tf) - der Node ist damit direkt nach dem Bootstrap
    Ready, ohne zweiten Schritt von außen.

    Ein Update ist deshalb ein `tf apply` auf dieses Modul und kein
    `helm upgrade`.
  EOT
  type        = string
  default     = "1.20.1"
}

variable "hubble_relay_enabled" {
  description = <<-EOT
    Hubble-Relay ausrollen. Standardmäßig aus, weil das RAM-Budget knapp ist
    (siehe vm_memory_mib). Flows lassen sich auch ohne Relay ansehen:

      kubectl -n kube-system exec ds/cilium -- hubble observe --follow

    Mit dem Relay geht auch TLS für Hubble an - die Zertifikate entstehen dann
    über einen CronJob im Cluster, siehe values/cilium.yaml.tftpl.
  EOT
  type        = bool
  default     = false
}

variable "hubble_ui_enabled" {
  description = "Hubble-UI ausrollen. Braucht Relay und nochmals RAM; für einen einzelnen Node selten den Platz wert."
  type        = bool
  default     = false

  validation {
    condition     = !var.hubble_ui_enabled || var.hubble_relay_enabled
    error_message = "Die Hubble-UI spricht über den Relay - ohne hubble_relay_enabled bleibt sie ohne Daten."
  }
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
  description = "libvirt-Connection-URI. Ohne läuft alles gegen den lokalen libvirt; für entfernten Hypervisor: qemu+ssh://root@<host>/system"
  type        = string
  default     = "qemu:///system"
}

variable "libvirt_pool" {
  description = "Storage-Pool für ISO und System-Disk. Default ist der, den eine lokale libvirt-Installation mitbringt; auf dem Hypervisor der dortige Pool. Siehe manage_pool."
  type        = string
  default     = "default"
}

variable "manage_pool" {
  description = <<-EOT
    Den Pool hier anlegen statt einen vorhandenen zu benutzen. Aus, weil ein
    libvirt-Objekt in zwei Terraform-States beim Zerstören zur Fehlerquelle
    wird. Einschalten, wenn dieses Modul allein läuft; dann auch pool_path setzen.

    Vor dem ersten Apply gegenprüfen, statt es anzunehmen:

      virsh --connect "$libvirt_uri" pool-list --all

    Fehlt der Pool und bleibt manage_pool aus, scheitert erst das Anlegen der
    Volumes mit "Storage pool not found".
  EOT
  type        = bool
  default     = false
}

variable "pool_path" {
  description = <<-EOT
    Verzeichnis des Pools, nur relevant bei manage_pool = true.
  EOT
  type        = string
  default     = "/var/lib/libvirt/images"

  #
  # Kreuzprobe gegen den häufigsten Fehlgriff: Host-Pfad, aber lokaler
  # Hypervisor. Ohne sie legt Terraform den Pool klaglos auf der Arbeitsstation
  # an, und der Fehler fällt erst auf, wenn die VM nicht startet.
  #
  validation {
    condition = !(
      (startswith(var.pool_path, "/mnt/user/") || startswith(var.pool_path, "/mnt/cache/")) &&
      (var.libvirt_uri == "qemu:///system" || var.libvirt_uri == "qemu:///session")
    )
    error_message = "pool_path zeigt auf einen Host-Share, libvirt_uri aber auf den lokalen Hypervisor."
  }
}

#
# Netzanbindung
#
# Drei Wege, in dieser Reihenfolge ausgewertet:
#
#   macvtap  - lan_macvtap_dev gesetzt. Für Hosts ohne Bridging.
#   Bridge   - lan_bridge gesetzt.
#   libvirt  - keins von beidem: vorhandenes libvirt-Netz, lokaler Test.
#
variable "lan_macvtap_dev" {
  description = <<-EOT
    Physisches Interface für ein macvtap-Bein. Nötig auf Hosts ohne Bridging -
    zeigt `ip -br link` dort kein br0, sondern nur bond0/ethX, gehört dieses
    Interface hierher.

    macvtap heißt: LAN und VM erreichen einander, VM und Hypervisor nicht. Von
    der Arbeitsstation ist der Node also erreichbar, aus einer SSH-Sitzung auf
    dem Hypervisor nicht. Docker-Container in einem macvlan-Netz auf demselben
    Parent dagegen schon.
  EOT
  type        = string
  default     = null
}

variable "lan_bridge" {
  description = "Vorhandene Host-Bridge, wenn lan_macvtap_dev nicht gesetzt ist (meist \"br0\")."
  type        = string
  default     = null
}

variable "lan_libvirt_network" {
  description = "Vorhandenes libvirt-Netz, wenn weder macvtap noch Bridge gesetzt sind (lokaler Test: \"default\")."
  type        = string
  default     = "default"
}

variable "lan_cidr" {
  description = "Netz, in dem der Node steht. Default ist das des libvirt-Netzes \"default\"."
  type        = string
  default     = "192.168.122.0/24"

  validation {
    condition     = can(cidrhost(var.lan_cidr, 0))
    error_message = "lan_cidr muss ein CIDR sein, z. B. 192.168.1.0/24."
  }
}

variable "lan_ip" {
  description = <<-EOT
    Feste Adresse des Nodes, außerhalb des DHCP-Bereichs und kollisionsfrei.
    Zugleich Kubernetes-API-Endpoint und talosctl-Ziel - sie steht deshalb auch
    in kubeconfig und talosconfig.

    Der Default liegt im libvirt-Netz "default", dort aber innerhalb des
    DHCP-Bereichs (.2-.254): für einen Testlauf unkritisch, für Dauerbetrieb
    den Bereich in der Netzdefinition verkleinern.
  EOT
  type        = string
  default     = "192.168.122.230"
}

variable "lan_gateway" {
  description = "Default-Gateway. Lokal virbr0, sonst der Router."
  type        = string
  default     = "192.168.122.1"
}

variable "dns_servers" {
  description = <<-EOT
    Resolver des Nodes. Ohne DNS kommt er an keine Container-Images.

    Default ist der Resolver des libvirt-Netzes "default". Im LAN gehört
    hierher zunächst der Router und nicht ein eigener Resolver - ein Baustein
    weniger, der beim ersten Aufbau kaputt sein kann.
  EOT
  type        = list(string)
  default     = ["192.168.122.1"]

  validation {
    condition     = length(var.dns_servers) > 0
    error_message = "Mindestens ein Resolver nötig - ohne DNS kommt der Node an keine Images."
  }
}

variable "ntp_servers" {
  description = "NTP-Quellen; ohne korrekte Zeit schlagen etcd und die Zertifikatsprüfungen des Kubelets fehl. Default ist der öffentliche Pool, weil das libvirt-Netz \"default\" kein NTP anbietet."
  type        = list(string)
  default     = ["pool.ntp.org"]
}

variable "node_mac" {
  description = "MAC des Nodes, im QEMU-Bereich 52:54:00 und kollisionsfrei. Dieselbe MAC wählt in der Machine-Config das Interface aus."
  type        = string
  default     = "52:54:00:00:00:01"
}

variable "maintenance_link" {
  description = <<-EOT
    Interface-Name, wie der Kernel das Bein beim Booten von der ISO benennt.
    Geht als `ip=`-Kernel-Parameter ins Image, damit der Node schon im
    Maintenance-Mode unter lan_ip erreichbar ist - vorher gäbe es dort nur
    DHCP, und der Config-Apply liefe ins Leere. Später wählt die Machine-Config
    das Interface über die MAC.

    "enp1s0" ist der erste virtio-Adapter im q35-Layout dieses Moduls.
    Gegenprüfen im Maintenance-Mode:
      talosctl get links --insecure -n <adresse> -e <adresse>
  EOT
  type        = string
  default     = "enp1s0"
}

variable "admin_sources" {
  description = <<-EOT
    Netze, aus denen die Talos-API und der kube-apiserver erreichbar sein
    sollen. Alles andere blockt die Ingress-Firewall des Nodes.

    Hierher gehören die Adressen, von denen aus administriert wird - nicht das
    ganze LAN, wenn es sich vermeiden lässt. Die Talos-API ist sonst nur durch
    Client-Zertifikate geschützt, und der kube-apiserver nimmt jede Anfrage
    entgegen, die er ablehnen will.

    Eine leere Liste ist nicht erlaubt: Sie würde den Node bei der nächsten
    Konfigurationsänderung unerreichbar machen.

    Vor dem ersten Apply gegen die eigene Adresse prüfen:
      ip -4 -br addr show scope global
  EOT
  type        = list(string)
  default     = ["192.168.122.0/24"]

  validation {
    condition     = length(var.admin_sources) > 0
    error_message = "admin_sources darf nicht leer sein - sonst ist die Talos-API von nirgends mehr erreichbar."
  }

  validation {
    condition     = alltrue([for s in var.admin_sources : can(cidrhost(s, 0))])
    error_message = "Jeder Eintrag in admin_sources muss ein CIDR sein, z. B. 192.168.1.2/32."
  }
}

#
# Cluster-Netz
#
variable "pod_subnet" {
  description = "Pod-CIDR. Darf sich mit nichts im LAN überschneiden."
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
    RAM der VM in MiB. 4096 trägt einen leeren Cluster mit Cilium und CoreDNS;
    Cilium kostet gegenüber Flannel rund ein halbes GB, Hubble-Relay und -UI
    kämen obendrauf (siehe hubble_relay_enabled). Vor jeder Erhöhung auf dem
    Hypervisor gegenprüfen:

      ssh root@<host> free -m

    Kein ForceNew-Feld: Ein Apply schreibt nur die Domain-Definition neu,
    wirksam wird der Wert beim nächsten Start der VM.
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
  description = "Größe der System-Disk in GiB. qcow2 ist dünn alloziert, der Platz wird also nicht sofort belegt. Großzügig wählen: Die Kapazität nachträglich zu ändern, ersetzt das Volume und damit den Cluster."
  type        = number
  default     = 100
}

variable "vm_data_disk_gib" {
  description = <<-EOT
    Groesse der zweiten Disk in GiB - der lokale Speicher des Clusters, auf dem
    Datenbanken und alles andere liegen, das fsync und Locking braucht. Talos
    reicht sie als User-Volume unter /var/mnt/local-path durch, local-path-
    provisioner macht daraus die Default-StorageClass (siehe
    k8s/flux/clusters/talos-cp1/local-path.yaml).

    Getrennt von der System-Disk, und zwar nicht wegen Geschwindigkeit -
    physisch ist es dieselbe SSD des Hypervisors. Der Grund ist die Kopplung:
    Auf /var teilen sich Datenbanken sonst die Partition mit dem
    containerd-Image-Cache und den Logs. Laeuft sie voll, setzt das kubelet
    DiskPressure, wirft Pods raus und raeumt Images weg - und die Datenbank
    ist genau dann betroffen, wenn der Cluster ohnehin Aerger hat.

    Grosszuegig waehlen: qcow2 ist duenn alloziert, der Platz wird also nicht
    belegt, bevor er gebraucht wird. Die Kapazitaet nachtraeglich zu aendern,
    ersetzt dagegen das Volume - und damit den Inhalt.
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
variable "efi_loader" {
  description = "Pfad zum OVMF-Code (schreibgeschützt, pflash). Leer: libvirt wählt selbst. Auf Unraid \"/usr/share/qemu/ovmf-x64/OVMF_CODE-pure-efi.fd\"."
  type        = string
  default     = ""
}

variable "efi_vars_template" {
  description = "Vorlage für den NVRAM-Speicher, die libvirt beim ersten Start nach nvram_dir kopiert. Auf Unraid \"/usr/share/qemu/ovmf-x64/OVMF_VARS-pure-efi.fd\"."
  type        = string
  default     = ""

  validation {
    condition     = (var.efi_loader == "") == (var.efi_vars_template == "")
    error_message = "efi_loader und efi_vars_template gehören zusammen - entweder beide setzen oder beide leer lassen."
  }
}

variable "nvram_dir" {
  description = "Verzeichnis für den NVRAM-Speicher je VM. Nur relevant bei gesetztem efi_loader. Muss auf dem Hypervisor existieren."
  type        = string
  default     = "/etc/libvirt/qemu/nvram"
}

#
# Ablauf
#
variable "wait_for_health" {
  description = <<-EOT
    Nach dem Bootstrap warten, bis Control Plane und Node gesund sind. Ohne den
    Check meldet `apply` auch dann Erfolg, wenn der Node NotReady bleibt.

    Auf false setzen für zwei Fälle:

      - `destroy` bei schon ausgeschalteter VM. Data Sources werden vor jedem
        Plan gelesen, auch beim Zerstören - der Check läuft sonst erst in
        seinen 20-Minuten-Timeout.
      - Reparaturläufe. Ist der Cluster kaputt, blockiert derselbe Check genau
        das `apply`, das den Fehler beheben würde.

    Beides als Flag mitgeben statt in die tfvars zu schreiben:

      terraform destroy -var wait_for_health=false
  EOT
  type        = bool
  default     = true
}
