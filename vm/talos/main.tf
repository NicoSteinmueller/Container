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
    #
    # Nur für `data "helm_template"`: Cilium wird lokal gerendert und als
    # Inline-Manifest in die Machine-Config gelegt. Es wird von hier aus kein
    # Cluster angefasst - die eigentlichen Helm-Releases stehen in
    # k8s/platform.
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
  node_name        = var.node_name != "" ? var.node_name : "${var.cluster_name}-cp1"
  cluster_endpoint = "https://${var.lan_ip}:6443"

  lan_prefix = tonumber(split("/", var.lan_cidr)[1])
  dmz_prefix = tonumber(split("/", var.dmz_cidr)[1])

  #
  # Das LAN-Bein hängt entweder an einer vorhandenen Host-Bridge (Unraid: br0)
  # oder - für lokale Tests - an einem vorhandenen libvirt-Netz. merge() statt
  # eines ternären Ausdrucks, weil die beiden Zweige unterschiedliche
  # Objekttypen haben (identisch zu vm/edge/main.tf).
  #
  lan_source = merge(
    var.lan_bridge != null ? { bridge = { bridge = var.lan_bridge } } : {},
    var.lan_bridge == null ? { network = { network = var.lan_libvirt_network } } : {},
  )

  cilium_values = templatefile("${path.module}/values/cilium.yaml.tftpl", {
    lan_ip               = var.lan_ip
    node_dmz_ip          = var.node_dmz_ip
    hubble_relay_enabled = var.hubble_relay_enabled
    hubble_ui_enabled    = var.hubble_ui_enabled
  })
}

# =====================================================================
# Image
# =====================================================================

#
# Schematic beschreibt, welche System-Extensions ins Image gehören. Die
# resultierende ID landet im State und wird für Boot-ISO und Installer-Image
# verwendet - damit bleiben ISO und installiertes System deckungsgleich.
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
# Cilium
# =====================================================================

#
# Rendert das Chart lokal. Kein Cluster-Zugriff, kein kubeconfig - das
# Ergebnis ist eine YAML-Zeichenkette, die unten als Inline-Manifest in die
# Machine-Config geht.
#
# Damit ist das CNI Teil der Maschine und nicht ein zweiter Schritt nach dem
# Bootstrap: Talos legt die Manifeste beim Start der Control Plane an, der
# Node wird Ready, und `data.talos_cluster_health` kann tatsächlich auf einen
# gesunden Cluster warten statt auf ein Zeitfenster.
#
# Preis: Die Machine-Config wird groß (mehrere hundert KB), und ein
# Cilium-Update ist eine Config-Änderung mit `terraform apply` statt eines
# `helm upgrade`. Beides ist hier gewollt - der Clusterzustand soll aus dem
# Repo kommen.
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
resource "libvirt_volume" "system" {
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

  # Muss nach einem Host-Reboot von selbst wiederkommen - sonst laufen sowohl
  # die öffentlichen als auch die internen Namen ins Leere.
  autostart = true

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

    # q35 hängt alle Geräte hinter PCIe-Root-Ports, die SeaBIOS nicht
    # enumeriert - der Gast sähe kein einziges virtio-Gerät. Deshalb OVMF;
    # ausführlich in vm/talos-test/README.md.
    firmware = "efi"

    firmware_info = {
      features = [
        # Secure Boot bleibt vorerst aus, sonst wählt libvirt automatisch das
        # OVMF-Image mit den Microsoft-Keys und die Talos-ISO wird abgelehnt.
        # Für Secure Boot braucht es die secureboot-Varianten aus der Image
        # Factory und eigene Keys - ein eigener Schritt.
        { name = "enrolled-keys", enabled = "no" },
        { name = "secure-boot", enabled = "no" },
      ]
    }

    # Reihenfolge ist Absicht: Bei leerer Disk fällt die Firmware auf die ISO
    # zurück (Maintenance-Mode). Nach der Installation bootet die VM von Disk,
    # obwohl die ISO angehängt bleibt.
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
            pool   = libvirt_volume.system.pool
            volume = libvirt_volume.system.name
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

    #
    # Zwei Beine, mehr nicht:
    #
    #   lan - Heimnetz. Talos-API, Kubernetes-API, ingress-internal.
    #   dmz - das von vm/edge angelegte isolierte Segment. Hier hängen
    #         ingress-public, die CrowdSec-LAPI und die interne CA.
    #
    # Das DMZ-Netz wird bewusst nicht hier angelegt: Es gehört zur Edge-Seite
    # (dort ohne Adresse auf dem Host und ohne DHCP definiert) und würde sonst
    # von zwei Modulen verwaltet. vm/edge muss also zuerst laufen.
    #
    interfaces = [
      {
        mac    = { address = var.mac_lan }
        model  = { type = "virtio" }
        source = local.lan_source
      },
      {
        mac   = { address = var.mac_dmz }
        model = { type = "virtio" }
        source = {
          network = {
            network = var.dmz_network_name
          }
        }
      },
    ]

    # Talos loggt Boot und Installation auf die serielle Konsole. Da es kein
    # SSH gibt, ist das neben talosctl der einzige Weg, einem fehlgeschlagenen
    # Boot zuzusehen - und der Notzugang, wenn die Ingress-Firewall aussperrt:
    #   virsh -c qemu:///system console homelab-cp1
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

    # Gegenstück zur qemu-guest-agent-Extension: sauberes Herunterfahren durch
    # libvirt.
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

    #
    # Kein VNC, kein SPICE - wie bei der Edge-VM. Ein zusätzlicher lauschender
    # Socket auf dem Hypervisor ist genau das, was hier niemand braucht;
    # Diagnose läuft über die serielle Konsole.
    #
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
# ACHTUNG: Diese Secrets liegen im Terraform-State. Der State ist per
# .gitignore ausgeschlossen und darf das lokale Dateisystem nicht
# unverschlüsselt verlassen - er ist gleichbedeutend mit Cluster-Admin.
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

    templatefile("${path.module}/patches/network.yaml.tftpl", {
      node_name   = local.node_name
      mac_lan     = var.mac_lan
      mac_dmz     = var.mac_dmz
      lan_ip      = var.lan_ip
      lan_prefix  = local.lan_prefix
      lan_cidr    = var.lan_cidr
      lan_gateway = var.lan_gateway
      node_dmz_ip = var.node_dmz_ip
      dmz_prefix  = local.dmz_prefix
      dns_servers = var.dns_servers
      ntp_servers = var.ntp_servers
    }),

    templatefile("${path.module}/patches/cluster.yaml.tftpl", {
      lan_ip         = var.lan_ip
      lan_cidr       = var.lan_cidr
      node_dmz_ip    = var.node_dmz_ip
      pod_subnet     = var.pod_subnet
      service_subnet = var.service_subnet
    }),

    file("${path.module}/patches/hardening.yaml"),

    templatefile("${path.module}/patches/ingress-firewall.yaml.tftpl", {
      default_action         = var.ingress_firewall_enforced ? "block" : "accept"
      node_name              = local.node_name
      admin_sources          = var.admin_sources
      lan_ip                 = var.lan_ip
      lan_cidr               = var.lan_cidr
      pod_subnet             = var.pod_subnet
      edge_dmz_ip            = var.edge_dmz_ip
      node_dmz_ip            = var.node_dmz_ip
      ingress_public_port    = var.ingress_public_port
      crowdsec_lapi_port     = var.crowdsec_lapi_port
      step_ca_port           = var.step_ca_port
      ingress_internal_ports = var.ingress_internal_ports
    }),

    # Cilium. Muss der letzte Patch sein - nicht technisch, sondern damit die
    # lesbaren Patches oben nicht hinter mehreren hundert Kilobyte gerendertem
    # YAML verschwinden.
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
# Überträgt die Config an den Node im Maintenance-Mode. Talos installiert sich
# daraufhin auf die Disk und rebootet.
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
# Blockiert, bis Control Plane und Node tatsächlich gesund sind - inklusive
# CNI, denn ohne Cilium bliebe der Node NotReady. Damit schlägt
# `terraform apply` fehl, statt einen halb fertigen Cluster als Erfolg zu
# melden.
#
data "talos_cluster_health" "this" {
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
# kubeconfig und talosconfig auf die Platte. k8s/platform liest genau diese
# Datei (kubeconfig_path) - so bleibt die Reihenfolge zwischen den Modulen
# sichtbar, statt über einen Remote-State verborgen zu sein.
#
# Beide Dateien sind Zugangsdaten und stehen in .gitignore.
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
