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
  default     = "v1.14.2"
}

variable "machine_config_contract" {
  description = <<-EOT
    Talos-Version, nach deren Format die Machine-Config erzeugt wird - nicht die
    Version auf dem Node. Ein neuerer Node nimmt Configs älterer Verträge an.

    Bewusst getrennt von talos_version: Mit v1.14 hat Talos die Config in
    eigene Dokumente zerlegt (KubeNetworkConfig, KubeProxyConfig, ...), und
    die Patches unter patches/ mussten dafür umziehen. Ein neuer Vertrag kann
    das wieder tun - und bringt neue Voreinstellungen mit (siehe
    patches/defaults.yaml). Deshalb von Hand heben, mit `talosctl apply-config
    --dry-run` gegen den Node vorher. Renovate fasst den Wert nicht an.
  EOT
  type        = string
  default     = "v1.14"
}

variable "kubernetes_version" {
  description = "Kubernetes-Version im Cluster."
  type        = string
  default     = "1.37.1"
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
  default     = "1.20.3"
}

variable "hubble_relay_enabled" {
  description = <<-EOT
    Hubble-Relay ausrollen. Standardmäßig aus - Flows lassen sich auch ohne
    Relay ansehen:

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

#
# Nodes
#
variable "nodes" {
  description = <<-EOT
    Die VMs des Clusters. Der Schlüssel ist der Kurzname: aus `cp1` wird der
    Hostname `<cluster_name>-cp1`, unter dem der Node auch in Kubernetes steht.
    Er geht in Domain-, Volume- und NVRAM-Namen ein - ihn zu ändern, baut den
    Node neu.

      role           "controlplane" genau einmal, sonst "worker". Die Control
                     Plane trägt etcd, das Cilium-Inline-Manifest und keinen
                     Taint - auf ihr läuft alles, was keinen eigenen Node
                     verlangt.

      lan_ip         Feste Adresse, außerhalb des DHCP-Bereichs und
                     kollisionsfrei. Bei der Control Plane zugleich
                     Kubernetes-API-Endpoint und talosctl-Ziel - sie steht
                     deshalb auch in kubeconfig und talosconfig.

      mac            MAC des LAN-Beins, im QEMU-Bereich 52:54:00 und
                     kollisionsfrei. Dieselbe MAC wählt in der Machine-Config
                     das Interface aus.

      public_ip      Adresse von ingress-public auf einem eigenen Bein mit
      public_mac     eigener MAC. Muss gleich der Adresse im Pool
                     `traefik-public` in k8s/flux/network/lb-ipam/IPPool.yaml
                     sein. Warum ein eigenes Bein: Die FRITZ!Box führt Geräte
                     nach MAC und gibt keine Ports frei an eine IP, die sich
                     eine MAC mit einer anderen teilt. Über L2-Announcement
                     trüge die Adresse die MAC des Nodes. Beide weglassen:
                     kein zweites Bein.

      nfs_address    Tunnel-Adresse des Nodes mit Präfix, z. B. 10.253.0.2/24 -
                     auf sie gehört der Export. Pflicht, sobald nfs_tunnel
                     gesetzt ist.

      vcpu           Anzahl vCPUs.

      memory_mib     RAM in MiB. 4096 trägt einen leeren Cluster mit Cilium
                     und CoreDNS. Vor jeder Erhöhung auf dem Hypervisor
                     gegenprüfen (`ssh root@<host> free -m`). Kein
                     ForceNew-Feld: Ein Apply schreibt nur die
                     Domain-Definition neu, wirksam wird der Wert beim
                     nächsten Start der VM.

      disk_gib       Größe der System-Disk in GiB.

      data_disk_gib  Größe der zweiten Disk in GiB - der lokale Speicher, auf
                     dem Datenbanken und alles andere liegen, das fsync und
                     Locking braucht. Talos reicht sie als User-Volume unter
                     /var/mnt/local-path durch, local-path-provisioner macht
                     daraus die Default-StorageClass (siehe
                     k8s/flux/storage/local-path/). Getrennt von der
                     System-Disk nicht wegen Geschwindigkeit, sondern damit
                     ein volles /var nicht die Datenbanken mitreißt (siehe
                     libvirt_volume.data).

      extensions     Offizielle System-Extensions zusätzlich zu
                     system_extensions, nur für diesen Node - etwa
                     "siderolabs/amdgpu" auf dem Node mit der GPU. Sie gehen
                     in seine Schematic ein; eine Änderung heißt neue ISO und
                     `talosctl upgrade` mit dem neuen Installer-Image.

      kernel_modules Kernelmodule, die Talos beim Start lädt - die einer
                     Extension lädt es nicht von selbst ("amdgpu").

      pci_devices    Host-PCI-Geräte, die libvirt an die VM durchreicht, als
                     "0000:09:00.0". Auf dem Host vorher an vfio-pci binden
                     (Unraid: Tools -> System Devices). Bei passthrough sperrt
                     QEMU den gesamten RAM der VM im Host - memory_mib ist
                     dann fest belegt, nicht nur reserviert.

      trim           Gelöschten Platz an den Host zurückgeben. qcow2 wächst
                     sonst nur.
                     Setzt `discard = "unmap"` an beiden Disks und ein
                     tägliches fstrim in Talos. An einer laufenden
                     VM wirkt der Disk-Teil erst nach Stopp und Start.

      labels         Kubernetes-Labels des Nodes, nur für Worker.
      taints         Taints, nur für Worker, als key = "value:Effect", z. B.
                     "homelab/gpu" = "amd:NoSchedule". Was dort laufen soll,
                     braucht dann eine Toleration - DaemonSets eingeschlossen.

    Beide Disk-Größen ohne Default und großzügig wählen: qcow2 ist dünn
    alloziert, der Platz wird erst belegt, wenn er gebraucht wird. Eine
    nachträglich geänderte Kapazität *ersetzt* dagegen das Volume - bei der
    System-Disk den Node, bei der Daten-Disk deren Inhalt. Ein geänderter
    Default träfe jeden Node, der sich auf ihn verlässt.

    Der Default ist ein Node im libvirt-Netz "default" für den lokalen
    Testlauf. Seine Adresse liegt dort innerhalb des DHCP-Bereichs (.2-.254):
    für einen Testlauf unkritisch, für Dauerbetrieb den Bereich in der
    Netzdefinition verkleinern.
  EOT
  type = map(object({
    role           = optional(string, "controlplane")
    lan_ip         = string
    mac            = string
    public_ip      = optional(string)
    public_mac     = optional(string)
    nfs_address    = optional(string)
    vcpu           = optional(number, 4)
    memory_mib     = optional(number, 4096)
    disk_gib       = number
    data_disk_gib  = number
    extensions     = optional(list(string), [])
    kernel_modules = optional(list(string), [])
    pci_devices    = optional(list(string), [])
    trim           = optional(bool, false)
    labels         = optional(map(string), {})
    taints         = optional(map(string), {})
  }))
  default = {
    cp1 = {
      lan_ip        = "192.168.122.230"
      mac           = "52:54:00:00:00:01"
      disk_gib      = 200
      data_disk_gib = 400
    }
  }

  validation {
    condition     = alltrue([for key in keys(var.nodes) : can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", key))])
    error_message = "Die Schlüssel in nodes werden Teil des Hostnamens: Kleinbuchstaben, Ziffern und Bindestriche, z. B. cp1."
  }

  validation {
    condition     = alltrue([for node in values(var.nodes) : contains(["controlplane", "worker"], node.role)])
    error_message = "role ist \"controlplane\" oder \"worker\"."
  }

  validation {
    condition = alltrue([
      for node in values(var.nodes) : node.role == "worker" || (length(node.labels) == 0 && length(node.taints) == 0)
    ])
    error_message = "labels und taints nur an Workern: Die Control Plane trägt die festen Labels aus patches/node.yaml.tftpl und bewusst keinen Taint."
  }

  validation {
    condition = alltrue(flatten([
      for node in values(var.nodes) : [for effect in values(node.taints) : can(regex("^([^:]*:)?(NoSchedule|PreferNoSchedule|NoExecute)$", effect))]
    ]))
    error_message = "Ein Taint ist \"value:Effect\" oder nur \"Effect\", Effect eins von NoSchedule, PreferNoSchedule, NoExecute."
  }

  validation {
    condition = alltrue(flatten([
      for node in values(var.nodes) : [for dev in node.pci_devices : can(regex("^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\\.[0-7]$", dev))]
    ]))
    error_message = "pci_devices im Format von lspci -D, z. B. \"0000:09:00.0\" (Kleinbuchstaben)."
  }

  validation {
    condition     = length(distinct(flatten([for node in values(var.nodes) : node.pci_devices]))) == length(flatten([for node in values(var.nodes) : node.pci_devices]))
    error_message = "Ein PCI-Gerät lässt sich nur an eine VM durchreichen."
  }

  validation {
    condition     = length([for node in values(var.nodes) : node if node.role == "controlplane"]) == 1
    error_message = "Genau ein Node mit role = \"controlplane\". Mehrere bräuchten eine gemeinsame API-Adresse (VIP), die dieses Modul nicht anlegt."
  }

  validation {
    condition     = length(distinct([for node in values(var.nodes) : node.lan_ip])) == length(var.nodes)
    error_message = "Jeder Node braucht eine eigene lan_ip."
  }

  validation {
    condition = (
      length(distinct([for mac in concat([for node in values(var.nodes) : node.mac], compact([for node in values(var.nodes) : node.public_mac])) : lower(mac)])) ==
      length(concat([for node in values(var.nodes) : node.mac], compact([for node in values(var.nodes) : node.public_mac])))
    )
    error_message = "Jede MAC in nodes - mac wie public_mac - darf nur einmal vorkommen."
  }

  validation {
    condition     = alltrue([for node in values(var.nodes) : (node.public_ip == null) == (node.public_mac == null)])
    error_message = "public_ip und public_mac gehören zusammen - entweder beide setzen oder beide weglassen."
  }

  validation {
    condition = var.nfs_tunnel == null || alltrue([
      for node in values(var.nodes) : can(regex("^[0-9.]+/[0-9]+$", node.nfs_address)) && can(cidrhost(node.nfs_address, 0))
    ])
    error_message = "Mit nfs_tunnel braucht jeder Node eine nfs_address mit Präfix, z. B. 10.253.0.2/24."
  }
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
# NFS über WireGuard
#
variable "nfs_tunnel" {
  description = <<-EOT
    WireGuard-Tunnel zum NFS-Server. NFS selbst kennt mit `sec=sys` keine
    Anmeldung, der Export vertraut der Quelladresse. Durch den Tunnel steht
    der Export auf der nfs_address des Nodes (var.nodes), und ein Paket von
    dort nimmt der Host nur an, wenn es mit dem Schlüssel des Nodes signiert
    ist.

    Die Schlüsselpaare der Nodes erzeugt dieses Modul (Output `nodes`, Feld
    `nfs_tunnel_public_key`); der private Teil liegt nur im State. Die Werte
    des Hosts kommen aus dessen WireGuard-Konfiguration:

      host_public_key  öffentlicher Schlüssel des Tunnels auf dem Host
      host_endpoint    <LAN-Adresse>:<Port>, auf dem der Host lauscht
      host_address     Tunnel-Adresse des Hosts - `server` der StorageClass
      node_port        UDP-Port der Nodes, damit der Host auch von sich aus
                       verbinden kann

    null: kein Tunnel, etwa für den lokalen Testlauf.
  EOT
  type = object({
    host_public_key = string
    host_endpoint   = string
    host_address    = string
    node_port       = optional(number, 51820)
  })
  default = null

  validation {
    condition     = var.nfs_tunnel == null || can(regex("^[A-Za-z0-9+/]{43}=$", var.nfs_tunnel.host_public_key))
    error_message = "host_public_key muss ein WireGuard-Schlüssel sein (44 Zeichen Base64, endet auf =)."
  }

  validation {
    condition     = var.nfs_tunnel == null || can(regex("^[0-9.]+:[0-9]+$", var.nfs_tunnel.host_endpoint))
    error_message = "host_endpoint muss <IPv4>:<Port> sein, z. B. 192.168.1.3:51821."
  }

  validation {
    condition     = var.nfs_tunnel == null || can(cidrhost("${var.nfs_tunnel.host_address}/32", 0))
    error_message = "host_address ist eine Adresse ohne Präfix, z. B. 10.253.0.1."
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
# VM
#
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
