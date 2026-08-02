terraform {
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "0.9.8"
    }
  }
}

provider "libvirt" {
  uri = var.libvirt_uri
}

locals {
  #
  # Bewusst auf einen Snapshot gepinnt statt auf .../latest/: der Volume-Name
  # trägt den Snapshot, und nur so ist nachvollziehbar, welches Image tatsächlich
  # in der laufenden VM steckt. Neue Snapshots stehen unter
  # https://cloud.debian.org/images/cloud/${var.debian_codename}/
  #
  debian_image = "debian-${var.debian_version}-genericcloud-amd64-${var.debian_image_snapshot}.qcow2"
  debian_url   = "https://cloud.debian.org/images/cloud/${var.debian_codename}/${var.debian_image_snapshot}/${local.debian_image}"

  lan_prefix = tonumber(split("/", var.lan_cidr)[1])
  dmz_prefix = tonumber(split("/", var.dmz_cidr)[1])

  # Der Pool wird entweder hier angelegt (Unraid: es gibt keinen) oder es wird
  # ein vorhandener verwendet - siehe manage_pool.
  pool_name = var.manage_pool ? libvirt_pool.domains[0].name : var.libvirt_pool

  #
  # Das LAN-Bein hängt entweder an einer vorhandenen Host-Bridge (Unraid: br0)
  # oder - für lokale Tests - an einem vorhandenen libvirt-Netz. merge() statt
  # eines ternären Ausdrucks, weil die beiden Zweige unterschiedliche
  # Objekttypen haben und Terraform die sonst nicht vereinheitlichen kann.
  #
  #
  # Entweder libvirt die Firmware aussuchen lassen oder feste Pfade vorgeben -
  # siehe efi_loader. Beide Zweige führen dieselben Attribute, weil Terraform
  # sonst die Typen der beiden Ergebnisse nicht vereinheitlichen kann; was
  # nicht gilt, steht auf null und wird vom Provider weggelassen.
  #
  firmware = var.efi_loader == "" ? {
    firmware = "efi"

    firmware_info = {
      features = [
        # Secure Boot bleibt aus, damit libvirt nicht automatisch das
        # OVMF-Image mit den Microsoft-Keys wählt.
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

    # Je VM ein eigener Variablenspeicher; libvirt legt ihn beim ersten Start
    # aus der Vorlage an.
    nv_ram = {
      nv_ram   = "${var.nvram_dir}/${var.vm_name}_VARS.fd"
      template = var.efi_vars_template
    }
  }

  #
  # Drei Wege ins Heimnetz, in dieser Reihenfolge:
  #
  #   macvtap   - lan_macvtap_dev gesetzt. Für Unraid-Hosts ohne Bridging:
  #               dort existiert kein br0, sondern nur bond0/ethX.
  #   Bridge    - lan_bridge gesetzt (Unraid mit Bridging, sonst br0).
  #   libvirt   - keins von beidem: vorhandenes libvirt-Netz, lokaler Test.
  #
  # merge() statt verschachtelter Bedingungen, weil die Zweige
  # unterschiedliche Objekttypen haben und Terraform die sonst nicht
  # vereinheitlichen kann.
  #
  lan_source = merge(
    var.lan_macvtap_dev != null ? { direct = { dev = var.lan_macvtap_dev, mode = "bridge" } } : {},
    var.lan_macvtap_dev == null && var.lan_bridge != null ? { bridge = { bridge = var.lan_bridge } } : {},
    var.lan_macvtap_dev == null && var.lan_bridge == null ? { network = { network = var.lan_libvirt_network } } : {},
  )

  #
  # Ableitungen, damit dieselbe Adresse nicht an drei Stellen gepflegt werden
  # muss: Regelsatz, Traefik-Konfiguration und die Skripte auf der VM.
  #
  step_ca_ip           = var.step_ca_ip != "" ? var.step_ca_ip : var.cluster_ingress_ip
  cert_common_name     = var.cert_common_name != "" ? var.cert_common_name : "${var.vm_name}.dmz"
  lapi_url             = "https://${var.cluster_ingress_ip}:${var.crowdsec_lapi_port}"
  pki_dir              = "/etc/traefik/pki"
  secrets_dir          = "/etc/traefik/secrets"
  step_path            = "/etc/step"
  staging_dir          = "/usr/local/share/edge"
  appsec_strict_addr   = "127.0.0.1:7422"
  appsec_patching_addr = "127.0.0.1:7423"

  # Vollständige Hostnamen aus subdomain + domain, sofern nicht explizit gesetzt.
  services = [
    for s in var.public_services : merge(s, {
      host = s.host != "" ? s.host : "${s.subdomain}.${var.domain}"
    })
  ]

  nftables_ruleset = templatefile("${path.module}/templates/nftables.nft.tftpl", {
    lan_ip            = var.lan_ip
    lan_cidr          = var.lan_cidr
    dmz_cidr          = var.dmz_cidr
    edge_dmz_ip       = var.edge_dmz_ip
    ingress_ip        = var.cluster_ingress_ip
    ingress_port      = var.cluster_ingress_port
    lapi_port         = var.crowdsec_lapi_port
    dns_servers       = var.dns_servers
    ntp_servers       = var.ntp_servers
    admin_sources     = var.admin_sources
    public_https_port = var.public_https_port
    http3_enabled     = var.http3_enabled
    egress_open       = var.egress_open
    egress_targets    = var.egress_targets
    egress_tcp_ports  = var.egress_tcp_ports

    # Stufen 2-6: interne CA und die Propagationsprüfung der ACME-Challenge.
    step_ca_ip           = local.step_ca_ip
    step_ca_port         = var.stack_enabled ? var.step_ca_port : 0
    cert_lifetime        = var.cert_lifetime
    acme_check_resolvers = var.stack_enabled ? var.acme_check_resolvers : []
  })

  sshd_config = templatefile("${path.module}/templates/sshd_config.tftpl", {
    lan_ip     = var.lan_ip
    admin_user = var.admin_user
  })

  # =====================================================================
  # Stufen 2-6
  # =====================================================================
  #
  # Alles, was zusätzlich auf die VM geht, als eine Map path -> Inhalt.
  # cloud-init schreibt sie in einer Schleife; damit bleibt die Liste der
  # Dateien an einer Stelle und die Templates werden nicht über das
  # cloud-init-Template verteilt.
  #
  # Die CrowdSec-Dateien landen zunächst nur unter ${local.staging_dir}.
  # Grund: Das Debian-Paket bringt eigene Conffiles mit und registriert im
  # postinst eine lokale LAPI. edge-install-stack kopiert sie erst danach an
  # ihren Platz - sonst entscheidet die Installationsreihenfolge darüber,
  # welche Konfiguration am Ende gilt.
  #
  traefik_files = {
    "/etc/traefik/traefik.yml" = {
      mode = "0644"
      content = templatefile("${path.module}/templates/traefik/traefik.yml.tftpl", {
        lan_ip                  = var.lan_ip
        public_https_port       = var.public_https_port
        http3_enabled           = var.http3_enabled
        upload_timeout          = var.upload_timeout_seconds
        log_level               = var.traefik_log_level
        acme_email              = var.acme_email
        acme_ca_server          = var.acme_ca_server
        acme_check_resolvers    = [for r in var.acme_check_resolvers : "${r}:53"]
        acme_dns_storage        = "${local.secrets_dir}/acme-dns.json"
        crowdsec_plugin_version = var.crowdsec_plugin_version
        sanitize_path           = var.entrypoint_sanitize_path
      })
    }

    "/etc/traefik/dynamic/tls.yml" = {
      mode = "0644"
      content = templatefile("${path.module}/templates/traefik/dynamic/tls.yml.tftpl", {
        tls_min_version = var.tls_min_version
      })
    }

    "/etc/traefik/dynamic/middlewares.yml" = {
      mode = "0644"
      content = templatefile("${path.module}/templates/traefik/dynamic/middlewares.yml.tftpl", {
        hsts_preload             = var.hsts_preload
        rate_default             = var.rate_limit_default
        rate_strict              = var.rate_limit_strict
        rate_relaxed             = var.rate_limit_relaxed
        crowdsec_enabled         = var.crowdsec_enabled
        crowdsec_mode            = var.crowdsec_mode
        crowdsec_update_interval = var.crowdsec_update_interval
        crowdsec_log_level       = upper(var.crowdsec_log_level)
        lapi_host                = "${var.cluster_ingress_ip}:${var.crowdsec_lapi_port}"
        appsec_strict_host       = local.appsec_strict_addr
        appsec_patching_host     = local.appsec_patching_addr
        appsec_body_limit        = var.appsec_body_limit
        admin_sources            = var.admin_sources
        pki_dir                  = local.pki_dir
        secrets_dir              = local.secrets_dir
      })
    }

    "/etc/traefik/dynamic/routers.yml" = {
      mode = "0644"
      content = templatefile("${path.module}/templates/traefik/dynamic/routers.yml.tftpl", {
        services     = local.services
        ingress_ip   = var.cluster_ingress_ip
        ingress_port = var.cluster_ingress_port

        # Nicht crowdsec_enabled: Die Middlewares werden erst eingebunden,
        # wenn die Zugangsdaten auf der VM liegen - sonst verweigert das
        # Plugin den Dienst und reißt jeden Router mit.
        crowdsec_armed = var.crowdsec_enabled && var.crowdsec_bouncer_armed
      })
    }

    "/etc/traefik/dynamic/servers-transport.yml" = {
      mode = "0644"
      content = templatefile("${path.module}/templates/traefik/dynamic/servers-transport.yml.tftpl", {
        ingress_server_name = var.cluster_ingress_server_name
        pki_dir             = local.pki_dir
        upload_timeout      = var.upload_timeout_seconds
        cert_lifetime       = var.cert_lifetime
      })
    }

    "/etc/systemd/system/traefik.service" = {
      mode    = "0644"
      content = file("${path.module}/files/traefik.service")
    }

    "/etc/systemd/system/edge-cert-renew.service" = {
      mode    = "0644"
      content = file("${path.module}/files/edge-cert-renew.service")
    }

    "/etc/systemd/system/edge-cert-renew.timer" = {
      mode    = "0644"
      content = file("${path.module}/files/edge-cert-renew.timer")
    }

    "/usr/local/sbin/edge-install-stack" = {
      mode = "0755"
      content = templatefile("${path.module}/files/install-stack.sh.tftpl", {
        traefik_version      = var.traefik_version
        traefik_sha256       = var.traefik_sha256
        step_cli_version     = var.step_cli_version
        step_cli_sha256      = var.step_cli_sha256
        crowdsec_enabled     = var.crowdsec_enabled
        crowdsec_collections = join(" ", var.crowdsec_collections)
        staging_dir          = local.staging_dir
        pki_dir              = local.pki_dir
        secrets_dir          = local.secrets_dir
      })
    }

    "/usr/local/sbin/edge-mtls-bootstrap" = {
      mode = "0755"
      content = templatefile("${path.module}/files/edge-mtls-bootstrap.sh.tftpl", {
        step_ca_url         = var.step_ca_url
        step_ca_fingerprint = var.step_ca_fingerprint
        cert_common_name    = local.cert_common_name
        cert_lifetime       = var.cert_lifetime
        pki_dir             = local.pki_dir
        step_path           = local.step_path
      })
    }

    "/usr/local/sbin/edge-cert-renew" = {
      mode = "0755"
      content = templatefile("${path.module}/files/edge-cert-renew.sh.tftpl", {
        pki_dir       = local.pki_dir
        step_path     = local.step_path
        cert_lifetime = var.cert_lifetime
        renew_before  = var.cert_renew_before
      })
    }
  }

  crowdsec_files = !var.crowdsec_enabled ? {} : {
    "${local.staging_dir}/crowdsec/acquis-traefik.yaml" = {
      mode    = "0644"
      content = file("${path.module}/templates/crowdsec/acquis-traefik.yaml")
    }

    "${local.staging_dir}/crowdsec/acquis-sshd.yaml" = {
      mode    = "0644"
      content = file("${path.module}/templates/crowdsec/acquis-sshd.yaml")
    }

    "${local.staging_dir}/crowdsec/acquis-appsec.yaml" = {
      mode = "0644"
      content = templatefile("${path.module}/templates/crowdsec/acquis-appsec.yaml.tftpl", {
        appsec_strict_addr   = local.appsec_strict_addr
        appsec_patching_addr = local.appsec_patching_addr
      })
    }

    "${local.staging_dir}/crowdsec/config.yaml.local" = {
      mode = "0644"
      content = templatefile("${path.module}/templates/crowdsec/config.yaml.local.tftpl", {
        log_level = var.crowdsec_log_level
      })
    }

    "${local.staging_dir}/crowdsec/edge-whitelist.yaml" = {
      mode = "0644"
      content = templatefile("${path.module}/templates/crowdsec/whitelist.yaml.tftpl", {
        admin_sources = var.admin_sources
      })
    }

    "${local.staging_dir}/crowdsec/firewall-bouncer.yaml" = {
      mode = "0600"
      content = templatefile("${path.module}/templates/crowdsec/firewall-bouncer.yaml.tftpl", {
        lapi_url         = local.lapi_url
        pki_dir          = local.pki_dir
        log_level        = var.crowdsec_log_level
        update_frequency = "${var.crowdsec_update_interval}s"
        ipv6_enabled     = !var.disable_ipv6
      })
    }

    "/usr/local/sbin/edge-crowdsec-connect" = {
      mode = "0755"
      content = templatefile("${path.module}/files/edge-crowdsec-connect.sh.tftpl", {
        machine_id  = var.vm_name
        lapi_url    = local.lapi_url
        pki_dir     = local.pki_dir
        secrets_dir = local.secrets_dir
      })
    }
  }

  stack_files = var.stack_enabled ? merge(local.traefik_files, local.crowdsec_files) : {}

  user_data = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    vm_name             = var.vm_name
    timezone            = var.timezone
    admin_user          = var.admin_user
    ssh_authorized_keys = var.ssh_authorized_keys
    extra_packages      = var.extra_packages
    auto_upgrade        = var.auto_upgrade
    disable_ipv6        = var.disable_ipv6
    ntp_servers         = var.ntp_servers
    nftables_ruleset    = local.nftables_ruleset
    sshd_config         = local.sshd_config
    stack_enabled       = var.stack_enabled
    stack_files         = local.stack_files
    pki_dir             = local.pki_dir
    secrets_dir         = local.secrets_dir
    step_path           = local.step_path
  })

  network_config = templatefile("${path.module}/templates/network-config.yaml.tftpl", {
    mac_lan     = var.mac_lan
    mac_dmz     = var.mac_dmz
    lan_ip      = var.lan_ip
    lan_prefix  = local.lan_prefix
    lan_gateway = var.lan_gateway
    dns_servers = var.dns_servers
    edge_dmz_ip = var.edge_dmz_ip
    dmz_prefix  = local.dmz_prefix
  })

  #
  # Cloud-Init wendet die per-instance-Module nur bei einer neuen instance-id an.
  # Sie hier an den Inhalt zu koppeln heißt: Config im Repo geändert ->
  # `terraform apply` -> Reboot -> Konfiguration sitzt wieder vollständig.
  #
  seed_hash = substr(sha256("${local.user_data}${local.network_config}"), 0, 12)
}

# =====================================================================
# Netzwerk
# =====================================================================

#
# Die Strecke Edge -> Cluster: ein reines L2-Segment.
#
# Bewusst ohne `ips` und damit ohne Adresse auf dem Hypervisor und ohne dnsmasq.
# Der Host soll kein Bein in dieser Zone haben, und ein DHCP-Server wäre hier
# ein zusätzlicher Dienst mit Ohren in der exponierten Zone. Edge-VM und
# Talos-Node adressieren beide statisch.
#
# Ohne `forward` ist das Netz isoliert - libvirt unterbindet Routing über den
# Host. Der Verkehr innerhalb der Bridge (Edge -> Ingress) bleibt davon
# unberührt, und genau darüber läuft der einzige Pfad aus der DMZ nach innen:
# eine IP, zwei Ports, mTLS. Siehe k8s/homelab-sicherheitskonzept.html,
# Abschnitte "Netzzonen" und "CrowdSec-Aufteilung".
#
resource "libvirt_network" "dmz" {
  name      = var.dmz_network_name
  autostart = true

  bridge = {
    name = var.dmz_bridge
    stp  = "on"
  }
}

# =====================================================================
# Storage
# =====================================================================

#
# Der Ablageort der VM-Disks: ein Verzeichnis-Pool auf ${var.pool_path}.
#
# "Pool" klingt nach mehr, als es ist - bei type = "dir" ist es nur libvirts
# Index über ein Verzeichnis. Was dort liegt, sind gewöhnliche qcow2-Dateien:
#
#   /mnt/user/domains/edge1.qcow2
#   /mnt/user/domains/debian-13-genericcloud-amd64-<snapshot>.qcow2
#   /mnt/user/domains/edge1-seed-<hash>.iso
#
# Damit liegen die Disks dort, wo Unraid seine VMs erwartet (Share `domains`,
# und damit im Blick der VM-Oberfläche und der Backup-Plugins) - und der
# manuelle `virsh pool-define-as`-Schritt entfällt. Unraid selbst definiert
# keine libvirt-Pools; ohne diese Ressource bricht der erste Apply mit
# "Storage pool 'default' not found" ab.
#
# Ganz ohne Pool geht es mit diesem Provider nicht: `libvirt_volume` verlangt
# einen, und daran hängen der Download des Cloud-Images, der
# Copy-on-Write-Layer und die Seed-ISO. Der Weg über Dateipfade
# (`source.file` in der Domain) hieße, all das per SSH auf dem Host
# nachzubauen - mehr bewegliche Teile für dasselbe Ergebnis.
#
resource "libvirt_pool" "domains" {
  count = var.manage_pool ? 1 : 0

  name = var.libvirt_pool
  type = "dir"

  target = {
    path = var.pool_path
  }

  create = {
    # build legt das Verzeichnis an, falls es fehlt; autostart sorgt dafür,
    # dass der Pool nach einem Neustart des Hosts wieder aktiv ist - sonst
    # startet keine VM.
    build     = true
    start     = true
    autostart = true
  }

  destroy = {
    # ACHTUNG: Auf keinen Fall true. `delete` löscht das Zielverzeichnis
    # mitsamt Inhalt - und das ist auf Unraid ein produktiver Share.
    # `terraform destroy` meldet den Pool damit nur ab, die Dateien bleiben.
    delete = false
  }
}

#
# Debian-Cloud-Image in der genericcloud-Variante: kein Nicht-virtio-Treiberballast,
# cloud-init an Bord, unattended-upgrades verfügbar. Grundlast rund 400 MB - das
# passt in die 1,5 GB, die das Konzept für die Edge-VM vorsieht.
#
resource "libvirt_volume" "debian_base" {
  name = local.debian_image
  pool = local.pool_name

  target = {
    format = {
      type = "qcow2"
    }
  }

  create = {
    content = {
      url = local.debian_url
    }
  }
}

#
# Copy-on-Write-Layer. Das Basis-Image bringt nur ~2 GB Dateisystem mit;
# aufgezogen wird beim ersten Boot durch growpart (siehe cloud-init.yaml.tftpl).
#
resource "libvirt_volume" "system" {
  name     = "${var.vm_name}.qcow2"
  pool     = local.pool_name
  capacity = var.vm_disk_gib * 1024 * 1024 * 1024

  target = {
    format = {
      type = "qcow2"
    }
  }

  backing_store = {
    path = libvirt_volume.debian_base.path
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
# ein Volume mit `url` ist derselbe wie in vm/ubuntu-desktop/main.tf. Der Hash im
# Namen erzwingt ein neues Volume, sobald sich die Konfiguration ändert - sonst
# bliebe die alte ISO liegen und die Änderung käme nie an.
#
resource "libvirt_volume" "seed" {
  name = "${var.vm_name}-seed-${local.seed_hash}.iso"
  pool = local.pool_name

  create = {
    content = {
      url = libvirt_cloudinit_disk.seed.path
    }
  }
}

# =====================================================================
# VM
# =====================================================================

resource "libvirt_domain" "edge" {
  name        = var.vm_name
  type        = "kvm"
  memory      = var.vm_memory_mib
  memory_unit = "MiB"
  vcpu        = var.vm_vcpu

  # Die Edge-VM muss nach einem Host-Reboot von selbst wiederkommen - sonst
  # laufen alle öffentlichen Namen ins Leere.
  autostart = true

  cpu = {
    mode = "host-passthrough"
  }

  # UEFI setzt ACPI zwingend voraus - ohne das verweigert libvirt die Definition.
  features = {
    acpi = true
  }

  #
  # q35 hängt alle Geräte hinter PCIe-Root-Ports, die SeaBIOS nicht enumeriert -
  # der Gast sähe kein einziges virtio-Gerät. Deshalb UEFI/OVMF; ausführlich in
  # vm/talos-test/README.md.
  #
  # Welche Firmware genau, entscheidet local.firmware: entweder libvirt sucht
  # sie selbst aus, oder es stehen feste Pfade drin (Unraid, siehe efi_loader).
  # Secure Boot bleibt in beiden Fällen aus - dafür braucht es signierte Images
  # und eigene Keys, das ist ein eigener Schritt.
  #
  os = merge({
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"

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
    # Zwei Beine, mehr nicht:
    #
    #   lan - Heimnetz hinter der Fritzbox. Hier kommt die Portfreigabe 443 an,
    #         hier geht ACME, DNS, NTP und der CrowdSec-Hub hinaus.
    #   dmz - isoliertes Segment zum Talos-Node, kein Gateway, keine Route.
    #
    # Die Zuordnung hängt nicht an der PCI-Reihenfolge: cloud-init adressiert per
    # MAC-Match, und der Regelsatz unterscheidet die Beine über Adressen statt
    # über Interface-Namen.
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
            network = libvirt_network.dmz.name
          }
        }
      },
    ]

    # Serielle Konsole für den Fall, dass die VM ohne Netz hochkommt oder der
    # Regelsatz SSH aussperrt:
    #   virsh -c qemu:///system console edge1
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

    # Sauberes Herunterfahren durch libvirt (Paket qemu-guest-agent).
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
    # Kein VNC und kein SPICE. Die VM braucht keine Grafik, und ein zusätzlicher
    # lauschender Socket auf dem Hypervisor ist genau das, was diese Zone nicht
    # haben soll. Diagnose läuft über die serielle Konsole.
    #
  }

  running = true
}
