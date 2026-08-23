#
# Ein Talos-Node mit Kubernetes, feste Adresse im LAN.
#
terraform {
  #
  # State in der Gitea-Package-Registry
  #
  backend "http" {
    address        = "https://git.local.nico-steinmueller.de/api/packages/nico/terraform/state/vm-talos"
    lock_address   = "https://git.local.nico-steinmueller.de/api/packages/nico/terraform/state/vm-talos/lock"
    unlock_address = "https://git.local.nico-steinmueller.de/api/packages/nico/terraform/state/vm-talos/lock"
    lock_method    = "POST"
    unlock_method  = "DELETE"
  }

  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "0.9.8"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "0.11.0"
    }
    #
    # Nur für `data "helm_template"`: Cilium wird lokal gerendert und als
    # Inline-Manifest in die Machine-Config gelegt. Von hier aus wird kein
    # Cluster angefasst - die eigentlichen Helm-Releases stehen als
    # HelmRelease in k8s/flux.
    #
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

provider "libvirt" {
  uri = var.libvirt_uri
}

provider "talos" {}

provider "helm" {}

locals {
  node_name        = "${var.cluster_name}-cp1"
  cluster_endpoint = "https://${var.lan_ip}:6443"
  lan_prefix       = tonumber(split("/", var.lan_cidr)[1])
  pool_name        = var.manage_pool ? libvirt_pool.domains[0].name : var.libvirt_pool

  #
  # Firmware von libvirt wählen lassen oder feste Pfade vorgeben (efi_loader).
  #
  firmware = var.efi_loader == "" ? {
    firmware = "efi"

    firmware_info = {
      features = [
        # Secure Boot aus: sonst wählt libvirt das OVMF mit den
        # Microsoft-Keys, gegen das die Talos-ISO nicht signiert ist -
        #   Access Denied -- rejected probably by Secure Boot
        { name = "enrolled-keys", enabled = "no" },
        { name = "secure-boot", enabled = "no" },
      ]
    }

    loader          = null
    loader_type     = null
    loader_readonly = null
    nv_ram          = null
    } : {
    firmware      = null
    firmware_info = null

    loader          = var.efi_loader
    loader_type     = "pflash"
    loader_readonly = "yes"

    # Je VM ein eigener Variablenspeicher, angelegt aus der Vorlage.
    nv_ram = {
      nv_ram   = "${var.nvram_dir}/${local.node_name}_VARS.fd"
      template = var.efi_vars_template
    }
  }

  #
  # macvtap, Bridge oder libvirt-Netz (siehe lan_macvtap_dev). merge() statt
  # verschachtelter Bedingungen: die Zweige haben verschiedene Objekttypen.
  #
  lan_source = merge(
    var.lan_macvtap_dev != null ? { direct = { dev = var.lan_macvtap_dev, mode = "bridge" } } : {},
    var.lan_macvtap_dev == null && var.lan_bridge != null ? { bridge = { bridge = var.lan_bridge } } : {},
    var.lan_macvtap_dev == null && var.lan_bridge == null ? { network = { network = var.lan_libvirt_network } } : {},
  )

  cilium_values = templatefile("${path.module}/values/cilium.yaml.tftpl", {
    hubble_relay_enabled = var.hubble_relay_enabled
    hubble_ui_enabled    = var.hubble_ui_enabled
  })
}

# =====================================================================
# Image
# =====================================================================

#
# Was ins Image gehört. Die ID landet im State und gilt für Boot-ISO *und*
# Installer - sonst gehen die Extensions beim Upgrade verloren.
#
resource "talos_image_factory_schematic" "this" {
  schematic = yamlencode({
    customization = {
      systemExtensions = {
        officialExtensions = var.system_extensions
      }

      #
      # Statische Adresse schon im Maintenance-Mode, sonst Henne-Ei: Der Node
      # bekäme von der ISO nur eine DHCP-Adresse, während der Config-Apply
      # unten auf var.lan_ip zielt - die er erst durch diese Config bekommt.
      #
      # dracut-Format:
      #   ip=<addr>:<server>:<gateway>:<maske>:<hostname>:<device>:<autoconf>
      #
      # Hostname bleibt leer: Steht dort etwas, gilt er in Talos als statisch
      # gesetzt und jede Config, die selbst einen setzt, wird abgelehnt.
      #
      extraKernelArgs = [
        "ip=${var.lan_ip}::${var.lan_gateway}:${cidrnetmask(var.lan_cidr)}::${var.maintenance_link}:off",
      ]
    }
  })
}

data "talos_image_factory_urls" "this" {
  talos_version = var.talos_version
  schematic_id  = talos_image_factory_schematic.this.id
  platform      = "metal"
  architecture  = "amd64"
}

# =====================================================================
# Cilium
# =====================================================================

#
# Rendert das Chart lokal. Kein Cluster-Zugriff, kein kubeconfig - das Ergebnis
# ist eine YAML-Zeichenkette, die unten als Inline-Manifest in die
# Machine-Config geht.
#
# Damit ist das CNI Teil der Maschine und nicht ein zweiter Schritt nach dem
# Bootstrap: Talos legt die Manifeste beim Start der Control Plane an, der Node
# wird Ready, und `data.talos_cluster_health` kann tatsächlich auf einen
# gesunden Cluster warten statt auf ein Zeitfenster.
#
# Preis: Die Machine-Config wächst um das gerenderte YAML (rund 60 KB), und ein
# Cilium-Update ist eine Config-Änderung mit `terraform apply` statt eines
# `helm upgrade`. Beides ist gewollt - der Clusterzustand soll aus dem Repo
# kommen.
#
data "helm_template" "cilium" {
  name       = "cilium"
  namespace  = "kube-system"
  repository = "https://helm.cilium.io"
  chart      = "cilium"
  version    = var.cilium_version

  kube_version = var.kubernetes_version
  include_crds = true

  values = [local.cilium_values]
}

# =====================================================================
# Storage
# =====================================================================

#
# Nur, wenn kein anderes Modul den Pool mitbringt - siehe manage_pool.
#
resource "libvirt_pool" "domains" {
  count = var.manage_pool ? 1 : 0

  name = var.libvirt_pool
  type = "dir"

  target = {
    path = var.pool_path
  }

  create = {
    build     = true
    start     = true
    autostart = true
  }

  destroy = {
    # Niemals true: `delete` entfernt das Zielverzeichnis samt Inhalt
    delete = false
  }
}

#
# Boot-ISO. Talos startet daraus in den Maintenance-Mode und wartet auf eine
# Machine-Config.
#
# Die Schematic-ID gehört in den Dateinamen: sonst hat eine geänderte Schematic
# denselben Volume-Namen, der Provider tauscht nur die Datei, das Domain-XML
# bleibt gleich - und die VM läuft weiter auf dem alten, gelöschten Inode.
#
resource "libvirt_volume" "talos_iso" {
  name = "${var.cluster_name}-${var.talos_version}-${substr(talos_image_factory_schematic.this.id, 0, 12)}.iso"
  pool = local.pool_name

  target = {
    format = {
      type = "iso"
    }
  }

  create = {
    content = {
      url = data.talos_image_factory_urls.this.urls.iso
    }
  }
}

#
# Leere System-Disk. Talos installiert sich beim Config-Apply selbst hierhin
# und rebootet von Disk.
#
resource "libvirt_volume" "system" {
  name     = "${local.node_name}.qcow2"
  pool     = local.pool_name
  capacity = var.vm_disk_gib * 1024 * 1024 * 1024

  target = {
    format = {
      type = "qcow2"
    }
  }
}

# =====================================================================
# VM
# =====================================================================

resource "libvirt_domain" "cp1" {
  name        = local.node_name
  type        = "kvm"
  memory      = var.vm_memory_mib
  memory_unit = "MiB"
  vcpu        = var.vm_vcpu

  # Muss nach einem Host-Reboot von selbst wiederkommen.
  autostart = true

  # Talos braucht moderne CPU-Features; spart außerdem Overhead bei
  # containerd und etcd.
  cpu = {
    mode = "host-passthrough"
  }

  # UEFI setzt ACPI zwingend voraus - ohne das verweigert libvirt die Definition.
  features = {
    acpi = true
  }

  #
  # q35 hängt alle Geräte hinter PCIe-Root-Ports, die SeaBIOS nicht enumeriert -
  # der Gast sähe *kein einziges* virtio-Gerät, weder NIC noch Disk, und der
  # Config-Apply liefe in "no route to host". Deshalb q35 mit UEFI; welche
  # Firmware genau, entscheidet local.firmware.
  #
  os = merge({
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"

    # Reihenfolge ist Absicht: Bei leerer Disk fällt die Firmware auf die ISO
    # zurück, danach bootet die VM von Disk, obwohl die ISO hängen bleibt.
    boot_devices = [
      { dev = "hd" },
      { dev = "cdrom" },
    ]
  }, local.firmware)

  devices = {
    disks = [
      {
        source = {
          volume = {
            pool   = libvirt_volume.system.pool
            volume = libvirt_volume.system.name
          }
        }
        target = {
          dev = "vda"
          bus = "virtio"
        }
        #
        # Ohne `cache` nimmt QEMU writeback und hält jeden Block des Gasts ein
        # zweites Mal im Page-Cache des Hosts.
        #
        # `none` gibt den Cache dem Gast allein (O_DIRECT)
        # `native` nutzt Linux-AIO und setzt O_DIRECT voraus
        #
        driver = {
          type  = "qcow2"
          cache = "none"
          io    = "native"
        }
      },
      {
        device = "cdrom"
        source = {
          volume = {
            pool   = libvirt_volume.talos_iso.pool
            volume = libvirt_volume.talos_iso.name
          }
        }
        target = {
          dev = "sda"
          bus = "sata"
        }
      },
    ]

    interfaces = [
      {
        mac    = { address = var.node_mac }
        model  = { type = "virtio" }
        source = local.lan_source
      },
    ]

    # Talos loggt Boot und Installation, neben talosctl der einzige Weg,
    # einem fehlgeschlagenen Boot zuzusehen:
    #   virsh -c qemu+ssh://root@<host>/system console <cluster>-cp1
    #
    # Bewusst leer: libvirt legt einen Chardev ohne Typangabe als `pty` an
    #
    # Gegenprobe, dass es wirklich pty ist:
    #   virsh -c qemu+ssh://root@<host>/system dumpxml <cluster>-cp1 | grep -A2 '<serial'
    serials = [
      {}
    ]

    consoles = [
      {
        target = {
          port = 0
          type = "serial"
        }
      }
    ]

    # sauberes Herunterfahren
    channels = [
      {
        source = {
          unix = {
            mode = "bind"
          }
        }
        target = {
          virt_io = {
            name = "org.qemu.guest_agent.0"
          }
        }
      }
    ]
  }

  running = true

  #
  # Wechselt die Boot-ISO, muss die VM neu entstehen. Sonst ändert sich am
  # Domain-XML nur der Dateiname des CD-Laufwerks - für libvirt ein
  # Medienwechsel an der laufenden Maschine, der Kernel bleibt der alte, und
  # Extensions wie Kernel-Parameter wirken scheinbar gar nicht.
  #
  # Talos-Upgrades laufen dagegen über `talosctl upgrade`; hier geht es um eine
  # geänderte Schematic, bevor der Cluster steht.
  #
  lifecycle {
    replace_triggered_by = [libvirt_volume.talos_iso]
  }
}

# =====================================================================
# Cluster
# =====================================================================

#
# Die komplette Cluster-PKI (etcd-, Kubernetes-, Talos-CAs, Bootstrap-Token).
#
# ACHTUNG: Diese Secrets liegen im State, der damit gleichbedeutend mit
# Cluster-Admin ist.
#
resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

data "talos_machine_configuration" "controlplane" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = "controlplane"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  config_patches = [
    # Installationsziel und Installer-Image mit denselben Extensions wie die ISO.
    yamlencode({
      machine = {
        install = {
          disk  = var.install_disk
          image = data.talos_image_factory_urls.this.urls.installer
          wipe  = false
        }
      }
    }),

    templatefile("${path.module}/patches/node.yaml.tftpl", {
      node_name   = local.node_name
      node_mac    = var.node_mac
      lan_ip      = var.lan_ip
      lan_prefix  = local.lan_prefix
      lan_gateway = var.lan_gateway
      dns_servers = var.dns_servers
      ntp_servers = var.ntp_servers
    }),

    # Muss nach node.yaml.tftpl kommen: räumt das von Talos erzeugte
    # HostnameConfig-Dokument weg, das mit dem dortigen Hostnamen kollidiert.
    file("${path.module}/patches/hostname.yaml"),

    templatefile("${path.module}/patches/cluster.yaml.tftpl", {
      pod_subnet     = var.pod_subnet
      service_subnet = var.service_subnet
    }),

    # Cilium. Muss der letzte Patch sein - nicht technisch, sondern damit die
    # lesbaren Patches oben nicht hinter dem gerenderten Chart verschwinden.
    yamlencode({
      cluster = {
        inlineManifests = [
          {
            name     = "cilium"
            contents = data.helm_template.cilium.manifest
          }
        ]
      }
    }),
  ]
}

#
# Config an den Node im Maintenance-Mode; Talos installiert sich daraufhin auf
# die Disk und rebootet.
#
resource "talos_machine_configuration_apply" "controlplane" {
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane.machine_configuration
  node                        = var.lan_ip
  endpoint                    = var.lan_ip

  timeouts = {
    create = "15m"
  }

  depends_on = [libvirt_domain.cp1]
}

#
# Initialisiert etcd. Genau einmal pro Cluster.
#
resource "talos_machine_bootstrap" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = var.lan_ip
  endpoint             = var.lan_ip

  timeouts = {
    create = "15m"
  }

  depends_on = [talos_machine_configuration_apply.controlplane]
}

#
# Blockiert, bis Control Plane und Node gesund sind. Der `count` ist der Notausgang
# für destroy- und Reparaturläufe, siehe wait_for_health.
#
data "talos_cluster_health" "this" {
  count = var.wait_for_health ? 1 : 0

  client_configuration = talos_machine_secrets.this.client_configuration
  control_plane_nodes  = [var.lan_ip]
  endpoints            = [var.lan_ip]

  timeouts = {
    read = "20m"
  }

  depends_on = [talos_machine_bootstrap.this]
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = [var.lan_ip]
  nodes                = [var.lan_ip]
}

resource "talos_cluster_kubeconfig" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = var.lan_ip
  endpoint             = var.lan_ip

  depends_on = [talos_machine_bootstrap.this]
}

#
# kubeconfig und talosconfig direkt auf die Platte, damit nach dem Apply kein
# Handgriff mehr nötig ist.
#
resource "local_sensitive_file" "kubeconfig" {
  content         = talos_cluster_kubeconfig.this.kubeconfig_raw
  filename        = "${path.module}/kubeconfig"
  file_permission = "0600"
}

resource "local_sensitive_file" "talosconfig" {
  content         = data.talos_client_configuration.this.talos_config
  filename        = "${path.module}/talosconfig"
  file_permission = "0600"
}
