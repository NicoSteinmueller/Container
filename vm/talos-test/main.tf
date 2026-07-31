terraform {
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "0.9.8"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "0.11.0"
    }
  }
}

provider "libvirt" {
  uri = var.libvirt_uri
}

provider "talos" {}

locals {
  cluster_endpoint = "https://${var.node_ip}:6443"
  node_name        = "${var.cluster_name}-cp1"
}

# =====================================================================
# Image
# =====================================================================

#
# Schematic beschreibt, welche System-Extensions ins Image gehören.
# Die resultierende ID landet im Terraform-State und wird sowohl für die
# Boot-ISO als auch für das Installer-Image verwendet - damit bleiben ISO
# und installiertes System garantiert deckungsgleich.
#
resource "talos_image_factory_schematic" "this" {
  schematic = yamlencode({
    customization = {
      systemExtensions = {
        officialExtensions = var.system_extensions
      }
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
# Netzwerk
# =====================================================================

resource "libvirt_network" "talos" {
  name      = var.cluster_name
  autostart = true

  forward = {
    mode = "nat"
  }

  bridge = {
    name = var.network_bridge
    stp  = "on"
  }

  ips = [
    {
      address = var.network_gateway
      prefix  = var.network_prefix

      dhcp = {
        ranges = [
          {
            start = var.dhcp_range.start
            end   = var.dhcp_range.end
          }
        ]

        # Feste Zuordnung, damit der Node vor und nach der Installation
        # unter derselben Adresse erreichbar ist.
        hosts = [
          {
            mac  = var.node_mac
            ip   = var.node_ip
            name = local.node_name
          }
        ]
      }
    }
  ]
}

# =====================================================================
# Storage
# =====================================================================

#
# Boot-ISO aus der Image Factory. Talos startet daraus in den Maintenance-Mode
# und wartet auf eine Machine-Config.
#
resource "libvirt_volume" "talos_iso" {
  name = "${var.cluster_name}-${var.talos_version}.iso"
  pool = var.libvirt_pool

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
# Leere System-Disk. Talos installiert sich beim Anwenden der Machine-Config
# selbst hierhin und rebootet anschließend von Disk.
#
resource "libvirt_volume" "talos_system" {
  name     = "${local.node_name}.qcow2"
  pool     = var.libvirt_pool
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
  autostart   = false

  # Talos braucht moderne CPU-Features; host-passthrough vermeidet außerdem
  # spürbaren Overhead bei containerd und etcd.
  cpu = {
    mode = "host-passthrough"
  }

  # UEFI setzt ACPI zwingend voraus - ohne das verweigert libvirt die Definition.
  features = {
    acpi = true
  }

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"

    # q35 hängt alle Geräte hinter PCIe-Root-Ports. Mit SeaBIOS werden die
    # nicht enumeriert - der Gast sieht dann kein einziges virtio-Gerät, also
    # weder NIC noch Disk. q35 ist für UEFI gebaut, deshalb OVMF.
    firmware = "efi"

    firmware_info = {
      features = [
        # libvirt wählt sonst automatisch das OVMF-Image mit einbetonierten
        # Microsoft-Keys; die Talos-ISO ist damit nicht signiert und wird
        # von Secure Boot abgelehnt ("Access Denied").
        #
        # Für Prod ist Secure Boot vorgesehen - dann aber mit den
        # secureboot-Varianten aus der Image Factory
        # (urls.iso_secureboot / urls.installer_secureboot) und eigenen Keys.
        { name = "enrolled-keys", enabled = "no" },
        { name = "secure-boot", enabled = "no" },
      ]
    }

    # Reihenfolge ist Absicht: Bei der leeren Disk fällt die Firmware auf die
    # ISO zurück (Maintenance-Mode). Nach der Installation bootet die VM von
    # Disk, obwohl die ISO angehängt bleibt.
    boot_devices = [
      { dev = "hd" },
      { dev = "cdrom" },
    ]
  }

  devices = {
    disks = [
      {
        source = {
          volume = {
            pool   = libvirt_volume.talos_system.pool
            volume = libvirt_volume.talos_system.name
          }
        }
        target = {
          dev = "vda"
          bus = "virtio"
        }
        driver = {
          type = "qcow2"
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
        type = "network"
        mac = {
          address = var.node_mac
        }
        model = {
          type = "virtio"
        }
        source = {
          network = {
            network = libvirt_network.talos.name
          }
        }
      }
    ]

    # Talos loggt den kompletten Boot- und Installationsvorgang auf die
    # serielle Konsole. Da es kein SSH gibt, ist das neben `talosctl` der
    # einzige Weg, einem fehlgeschlagenen Boot zuzusehen:
    #   virsh -c qemu:///system console talos-test-cp1
    serials = [
      {
        type = "pty"
      }
    ]

    consoles = [
      {
        type = "pty"
        target = {
          port = 0
          type = "serial"
        }
      }
    ]

    # Gegenstück zur qemu-guest-agent-Extension: ermöglicht sauberes
    # Herunterfahren durch libvirt.
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

    graphics = [
      {
        vnc = {
          auto_port = true
          listen    = "127.0.0.1"
        }
      }
    ]
  }

  running = true
}

# =====================================================================
# Talos-Cluster
# =====================================================================

#
# Erzeugt die komplette Cluster-PKI (etcd-, Kubernetes- und Talos-CAs,
# Bootstrap-Token, Verschlüsselungs-Secrets).
#
# ACHTUNG: Diese Secrets liegen im Terraform-State. Der State darf das
# lokale Dateisystem nicht verlassen bzw. muss verschlüsselt abgelegt werden
# (in diesem Repo ist *.tfstate per .gitignore ausgeschlossen).
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
    #
    # Kein machine.network.hostname hier: Talos übernimmt den Hostnamen aus der
    # DHCP-Reservierung (dnsmasq liefert "talos-test-cp1" mit). Wird er
    # zusätzlich in der v1alpha1-Config gesetzt, lehnt Talos die Config mit
    # "static hostname is already set in v1alpha1 config" ab.
    yamlencode({
      machine = {
        install = {
          disk  = var.install_disk
          image = data.talos_image_factory_urls.this.urls.installer
          wipe  = false
        }
      }
    }),
    file("${path.module}/patches/single-node.yaml"),
    file("${path.module}/patches/hardening.yaml"),
  ]
}

#
# Überträgt die Config an den Node im Maintenance-Mode. Talos installiert sich
# daraufhin auf die Disk und rebootet. Der Provider wartet, bis der Node
# über die Maintenance-API erreichbar ist - der ISO-Boot dauert je nach
# Host ein bis zwei Minuten.
#
resource "talos_machine_configuration_apply" "controlplane" {
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane.machine_configuration
  node                        = var.node_ip
  endpoint                    = var.node_ip

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
  node                 = var.node_ip
  endpoint             = var.node_ip

  timeouts = {
    create = "15m"
  }

  depends_on = [talos_machine_configuration_apply.controlplane]
}

#
# Blockiert, bis Control Plane und Kubernetes-Node tatsächlich gesund sind.
# Damit schlägt `terraform apply` fehl statt einen halb fertigen Cluster
# als Erfolg zu melden.
#
data "talos_cluster_health" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  control_plane_nodes  = [var.node_ip]
  endpoints            = [var.node_ip]

  timeouts = {
    read = "20m"
  }

  depends_on = [talos_machine_bootstrap.this]
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = [var.node_ip]
  nodes                = [var.node_ip]
}

resource "talos_cluster_kubeconfig" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = var.node_ip
  endpoint             = var.node_ip

  depends_on = [talos_machine_bootstrap.this]
}
