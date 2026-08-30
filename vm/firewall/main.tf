terraform {
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "0.9.9"
    }
  }
}

provider "libvirt" {
  uri = var.libvirt_uri
}

locals {
  alpine_branch = "v${join(".", slice(split(".", var.alpine_version), 0, 2))}"
  alpine_image  = "generic_alpine-${var.alpine_version}-x86_64-uefi-cloudinit-${var.alpine_image_revision}.qcow2"
  alpine_url    = "https://dl-cdn.alpinelinux.org/alpine/${local.alpine_branch}/releases/cloud/${local.alpine_image}"

  mgmt_prefix    = tonumber(split("/", var.mgmt_cidr)[1])
  dmz_prefix     = tonumber(split("/", var.dmz_cidr)[1])
  cluster_prefix = tonumber(split("/", var.cluster_cidr)[1])

  # busybox syslogd: -R leitet zusätzlich an einen Remote-Empfänger,
  # -L hält das lokale Log daneben am Leben.
  syslog_remote_opts = var.syslog_remote == null ? "" : " -R ${var.syslog_remote} -L"

  #
  # WAN hängt entweder an einer vorhandenen Host-Bridge (Unraid: br0) oder -
  # für lokale Tests - an einem vorhandenen libvirt-Netz. merge() statt eines
  # ternären Ausdrucks, weil die beiden Zweige unterschiedliche Objekttypen
  # haben und Terraform die sonst nicht vereinheitlichen kann.
  #
  wan_source = merge(
    var.wan_bridge != null ? { bridge = { bridge = var.wan_bridge } } : {},
    var.wan_bridge == null ? { network = { network = var.wan_libvirt_network } } : {},
  )

  nftables_ruleset = templatefile("${path.module}/templates/nftables.nft.tftpl", {
    lan_cidr            = var.lan_cidr
    mgmt_cidr           = var.mgmt_cidr
    mgmt_ip             = var.mgmt_ip
    dmz_cidr            = var.dmz_cidr
    cluster_cidr        = var.cluster_cidr
    wan_ip              = var.wan_ip
    edge_ip             = var.edge_ip
    cluster_ingress_ip  = var.cluster_ingress_ip
    egress_tcp_ports    = var.egress_tcp_ports
    egress_udp_ports    = var.egress_udp_ports
    admin_sources       = var.admin_sources
    cluster_admin_ports = var.cluster_admin_ports
    extra_forward_rules = var.extra_forward_rules
  })

  nftables_panic = templatefile("${path.module}/templates/nftables-panic.nft.tftpl", {
    mgmt_cidr = var.mgmt_cidr
    mgmt_ip   = var.mgmt_ip
  })

  interfaces_map = templatefile("${path.module}/templates/interfaces.map.tftpl", {
    mac_wan     = var.mac_wan
    mac_mgmt    = var.mac_mgmt
    mac_dmz     = var.mac_dmz
    mac_cluster = var.mac_cluster
  })

  sshd_config = templatefile("${path.module}/templates/sshd_config.tftpl", {
    mgmt_ip    = var.mgmt_ip
    admin_user = var.admin_user
  })

  user_data = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    vm_name              = var.vm_name
    timezone             = var.timezone
    admin_user           = var.admin_user
    ssh_authorized_keys  = var.ssh_authorized_keys
    extra_packages       = var.extra_packages
    auto_upgrade         = var.auto_upgrade
    syslog_remote_opts   = local.syslog_remote_opts
    nftables_ruleset     = local.nftables_ruleset
    nftables_panic       = local.nftables_panic
    interfaces_map       = local.interfaces_map
    fw_render_interfaces = file("${path.module}/files/fw-render-interfaces.sh")
    firewall_initd       = file("${path.module}/files/firewall.initd")
    sshd_config          = local.sshd_config
  })

  network_config = templatefile("${path.module}/templates/network-config.yaml.tftpl", {
    mac_wan            = var.mac_wan
    mac_mgmt           = var.mac_mgmt
    mac_dmz            = var.mac_dmz
    mac_cluster        = var.mac_cluster
    wan_ip             = var.wan_ip
    wan_prefix         = var.wan_prefix
    wan_gateway        = var.wan_gateway
    dns_servers        = var.dns_servers
    mgmt_ip            = var.mgmt_ip
    mgmt_prefix        = local.mgmt_prefix
    dmz_gateway_ip     = var.dmz_gateway_ip
    dmz_prefix         = local.dmz_prefix
    cluster_gateway_ip = var.cluster_gateway_ip
    cluster_prefix     = local.cluster_prefix
  })

  #
  # Cloud-Init wendet die per-instance-Module nur bei einer neuen instance-id
  # an. Sie hier an den Inhalt zu koppeln heißt: Config im Repo geändert ->
  # `terraform apply` -> Reboot -> Konfiguration sitzt wieder vollständig.
  #
  seed_hash = substr(sha256("${local.user_data}${local.network_config}"), 0, 12)
}

# =====================================================================
# Netzwerke
# =====================================================================

#
# Management: isoliertes Netz mit Adresse auf dem Hypervisor. Nur der Host
# kommt hier hinein - SSH ist damit weder aus dem LAN noch aus der DMZ
# erreichbar (k8s/Edge-Architektur.md, Abschnitt 5). Der Weg von außen führt
# über den Host als Sprungbrett.
#
# Kein DHCP: die Firewall adressiert alle Beine statisch, sonst könnte die
# nft-Regel auf $mgmt_ip ins Leere laufen.
#
resource "libvirt_network" "mgmt" {
  name      = var.mgmt_network_name
  autostart = true

  bridge = {
    name = var.mgmt_bridge
    stp  = "on"
  }

  ips = [
    {
      address = var.mgmt_host_ip
      prefix  = local.mgmt_prefix
    }
  ]
}

#
# DMZ und Cluster: reine L2-Segmente.
#
# Bewusst ohne `ips` und damit ohne Adresse auf dem Host und ohne dnsmasq. Der
# Hypervisor soll kein Bein in der DMZ haben, und Default-Gateway ist die
# Firewall - nicht libvirt. Folge: Gäste in diesen Segmenten (Edge-VM,
# Talos-Nodes) müssen statisch adressiert werden, es gibt dort keinen
# DHCP-Server.
#
# Ohne `forward` ist das Netz isoliert: libvirt unterbindet Routing über den
# Host. Der Verkehr innerhalb der Bridge - Gast zur Firewall-VM - bleibt davon
# unberührt, und genau darüber läuft die Segmentierung.
#
resource "libvirt_network" "dmz" {
  name      = var.dmz_network_name
  autostart = true

  bridge = {
    name = var.dmz_bridge
    stp  = "on"
  }
}

resource "libvirt_network" "cluster" {
  name      = var.cluster_network_name
  autostart = true

  bridge = {
    name = var.cluster_bridge
    stp  = "on"
  }
}

# =====================================================================
# Storage
# =====================================================================

#
# Alpine-Cloud-Image in der UEFI-Variante. Das BIOS-Image scheidet aus:
# q35 hängt alle Geräte hinter PCIe-Root-Ports, die SeaBIOS nicht enumeriert -
# der Gast sähe kein einziges virtio-Gerät (siehe vm/talos-test/README.md).
#
resource "libvirt_volume" "alpine_base" {
  name = "alpine-${var.alpine_version}-uefi-cloudinit.qcow2"
  pool = var.libvirt_pool

  target = {
    format = {
      type = "qcow2"
    }
  }

  create = {
    content = {
      url = local.alpine_url
    }
  }
}

#
# Copy-on-Write-Layer. Das Basis-Image bringt nur ~200 MB Dateisystem mit;
# aufgezogen wird beim ersten Boot durch growpart (siehe cloud-init.yaml.tftpl).
#
resource "libvirt_volume" "system" {
  name     = "${var.vm_name}.qcow2"
  pool     = var.libvirt_pool
  capacity = var.vm_disk_gib * 1024 * 1024 * 1024

  target = {
    format = {
      type = "qcow2"
    }
  }

  backing_store = {
    path = libvirt_volume.alpine_base.path
    format = {
      type = "qcow2"
    }
  }
}

resource "libvirt_cloudinit_disk" "seed" {
  name           = "${var.vm_name}-seed-${local.seed_hash}.iso"
  user_data      = local.user_data
  network_config = local.network_config

  meta_data = <<-EOT
    instance-id: ${var.vm_name}-${local.seed_hash}
    local-hostname: ${var.vm_name}
  EOT
}

#
# libvirt_cloudinit_disk legt die ISO nicht selbst im Pool ab; der Umweg über
# ein Volume mit `url` ist derselbe wie in vm/alpine/main.tf. Der Hash im Namen
# erzwingt ein neues Volume, sobald sich die Konfiguration ändert - sonst
# bliebe die alte ISO liegen und die Änderung käme nie an.
#
resource "libvirt_volume" "seed" {
  name = "${var.vm_name}-seed-${local.seed_hash}.iso"
  pool = var.libvirt_pool

  create = {
    content = {
      url = libvirt_cloudinit_disk.seed.path
    }
  }
}

# =====================================================================
# VM
# =====================================================================

resource "libvirt_domain" "firewall" {
  name        = var.vm_name
  type        = "kvm"
  memory      = var.vm_memory_mib
  memory_unit = "MiB"
  vcpu        = var.vm_vcpu

  # Die Firewall muss nach einem Host-Reboot von selbst wiederkommen -
  # sonst hängen DMZ und Cluster ohne Gateway in der Luft.
  autostart = true

  cpu = {
    mode = "host-passthrough"
  }

  # UEFI setzt ACPI zwingend voraus.
  features = {
    acpi = true
  }

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"
    firmware     = "efi"

    firmware_info = {
      features = [
        # Ohne das wählt libvirt das OVMF-Image mit den Microsoft-Keys, und das
        # Alpine-Image wird mit "Access Denied" abgewiesen.
        { name = "enrolled-keys", enabled = "no" },
        { name = "secure-boot", enabled = "no" },
      ]
    }

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
            pool   = libvirt_volume.seed.pool
            volume = libvirt_volume.seed.name
          }
        }
        target = {
          dev = "sda"
          bus = "sata"
        }
      },
    ]

    #
    # Reihenfolge = PCI-Reihenfolge im Gast. Die Zuordnung hängt trotzdem nicht
    # daran: Cloud-Init adressiert per MAC-Match, und fw-render-interfaces
    # erzeugt die nft-Defines aus denselben MACs.
    #
    interfaces = [
      # WAN - Heimnetz hinter der Fritzbox
      {
        mac    = { address = var.mac_wan }
        model  = { type = "virtio" }
        source = local.wan_source
      },
      # Management - nur der Hypervisor-Host
      {
        mac   = { address = var.mac_mgmt }
        model = { type = "virtio" }
        source = {
          network = {
            network = libvirt_network.mgmt.name
          }
        }
      },
      # DMZ - Edge-VM
      {
        mac   = { address = var.mac_dmz }
        model = { type = "virtio" }
        source = {
          network = {
            network = libvirt_network.dmz.name
          }
        }
      },
      # Cluster - Talos-Nodes
      {
        mac   = { address = var.mac_cluster }
        model = { type = "virtio" }
        source = {
          network = {
            network = libvirt_network.cluster.name
          }
        }
      },
    ]

    # Serielle Konsole für den Fall, dass die VM ohne Netz hochkommt:
    #   virsh -c qemu:///system console fw1
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

    # Gegenstück zum qemu-guest-agent: sauberes Herunterfahren durch libvirt.
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
