#
# Ein Talos-Node mit Kubernetes, feste Adresse im Heimnetz.
#
# Bewusst der kleinste Aufbau, der trägt: ein Bein, Talos-Default-CNI, keine
# DMZ, keine Ingress-Firewall, kein Plattform-Stack. Was hier steht, muss
# stehen bleiben, damit der Cluster überhaupt hochkommt oder erreichbar ist -
# alles Weitere kommt später und woanders.
#
terraform {
  #
  # Der State liegt in der Package-Registry von Gitea, nicht im Modul. Zwei
  # Gründe: Von jedem Gerät gilt derselbe Stand, und `lock_address` sperrt ihn
  # serverseitig für die Dauer eines Apply.
  #
  # Die Registry ist kein git-Repo: Der State landet nicht in einer Historie,
  # die mit jedem Apply um eine volle Kopie wächst.
  #
  # Zugangsdaten stehen bewusst nicht hier, sondern kommen aus der Umgebung -
  # TF_HTTP_USERNAME und TF_HTTP_PASSWORD, letzteres ein Gitea-Token mit
  # `write:package`. Ein Token an dieser Stelle wäre ein Geheimnis in einer
  # Datei, die nach GitHub geht.
  #
  # Vorerst nur dieses Modul. Die übrigen behalten ihren lokalen State, bis sie
  # einzeln umgestellt werden. Einrichtung: ../../gitea/README.md
  #
  backend "http" {
    address        = "https://git.local.nico-steinmueller.de/api/packages/nico/terraform/state/vm-talos-simple"
    lock_address   = "https://git.local.nico-steinmueller.de/api/packages/nico/terraform/state/vm-talos-simple/lock"
    unlock_address = "https://git.local.nico-steinmueller.de/api/packages/nico/terraform/state/vm-talos-simple/lock"
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

locals {
  node_name        = "${var.cluster_name}-cp1"
  cluster_endpoint = "https://${var.lan_ip}:6443"
  lan_prefix       = tonumber(split("/", var.lan_cidr)[1])
  pool_name        = var.manage_pool ? libvirt_pool.domains[0].name : var.libvirt_pool

  #
  # Entweder libvirt die Firmware aussuchen lassen oder feste Pfade vorgeben -
  # siehe efi_loader in variables.tf. Beide Zweige führen dieselben Attribute,
  # weil Terraform sonst die Typen nicht vereinheitlichen kann; was nicht gilt,
  # steht auf null und wird vom Provider weggelassen.
  #
  firmware = var.efi_loader == "" ? {
    firmware = "efi"

    firmware_info = {
      features = [
        # Secure Boot bleibt aus, sonst wählt libvirt automatisch das
        # OVMF-Image mit den einbetonierten Microsoft-Keys - und die
        # Talos-ISO ist damit nicht signiert:
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

    # Je VM ein eigener Variablenspeicher; libvirt legt ihn beim ersten Start
    # aus der Vorlage an.
    nv_ram = {
      nv_ram   = "${var.nvram_dir}/${local.node_name}_VARS.fd"
      template = var.efi_vars_template
    }
  }

  #
  # macvtap, Bridge oder libvirt-Netz - siehe lan_macvtap_dev. merge() statt
  # verschachtelter Bedingungen, weil die Zweige unterschiedliche Objekttypen
  # haben und Terraform die sonst nicht vereinheitlichen kann.
  #
  lan_source = merge(
    var.lan_macvtap_dev != null ? { direct = { dev = var.lan_macvtap_dev, mode = "bridge" } } : {},
    var.lan_macvtap_dev == null && var.lan_bridge != null ? { bridge = { bridge = var.lan_bridge } } : {},
    var.lan_macvtap_dev == null && var.lan_bridge == null ? { network = { network = var.lan_libvirt_network } } : {},
  )
}

# =====================================================================
# Image
# =====================================================================

#
# Die Schematic beschreibt, was ins Image gehört. Die resultierende ID landet
# im State und wird für Boot-ISO *und* Installer-Image verwendet - damit bleiben
# ISO und installiertes System deckungsgleich, und Extensions gehen beim
# Upgrade nicht verloren.
#
resource "talos_image_factory_schematic" "this" {
  schematic = yamlencode({
    customization = {
      systemExtensions = {
        officialExtensions = var.system_extensions
      }

      #
      # Statische Adresse schon im Maintenance-Mode.
      #
      # Ohne das gibt es ein Henne-Ei-Problem: Der Node bootet von der ISO in
      # den Maintenance-Mode und holt sich dort per DHCP irgendeine Adresse -
      # talos_machine_configuration_apply unten will die Config aber an
      # var.lan_ip übertragen, die der Node erst *durch* diese Config bekommt.
      # Der Apply läuft dann in seinen Timeout, während die VM auf dem
      # Hypervisor fröhlich als "gestartet" angezeigt wird.
      #
      # Format ist die dracut-Schreibweise, die Talos als Kernel-Parameter
      # unterstützt:
      #
      #   ip=<addr>:<server>:<gateway>:<maske>:<hostname>:<device>:<autoconf>
      #
      # Das Hostname-Feld bleibt leer. Steht dort etwas, wertet Talos das als
      # statisch gesetzten Hostnamen und lehnt jede Config ab, die ihrerseits
      # einen setzt. Der Hostname gehört in die Machine-Config, nicht in die
      # Bootzeile - diese hier gilt nur für das Zeitfenster davor.
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
# Storage
# =====================================================================

#
# Nur aktiv, wenn kein anderes Modul den Pool schon mitbringt - vm/edge legt
# denselben `homelab` an. Siehe manage_pool.
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
    # Niemals true: `delete` würde das Zielverzeichnis mitsamt Inhalt
    # entfernen - auf Unraid ein produktiver Share.
    delete = false
  }
}

#
# Boot-ISO aus der Image Factory. Talos startet daraus in den Maintenance-Mode
# und wartet auf eine Machine-Config.
#
# Die Schematic-ID gehört in den Dateinamen. Ohne sie hat eine geänderte
# Schematic - andere Extensions, andere Kernel-Parameter - zwar eine neue
# Download-URL, aber denselben Volume-Namen: Der Provider tauscht die Datei
# aus, das Domain-XML bleibt Zeichen für Zeichen gleich, und Terraform sieht
# keinen Grund, die VM anzufassen. Die läuft dann weiter auf dem alten, bereits
# gelöschten Inode, und die Änderung wirkt scheinbar überhaupt nicht.
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
# Leere System-Disk. Talos installiert sich beim Anwenden der Machine-Config
# selbst hierhin und rebootet anschließend von Disk.
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

  # Talos braucht moderne CPU-Features; host-passthrough vermeidet außerdem
  # spürbaren Overhead bei containerd und etcd.
  cpu = {
    mode = "host-passthrough"
  }

  # UEFI setzt ACPI zwingend voraus - ohne das verweigert libvirt die Definition.
  features = {
    acpi = true
  }

  #
  # q35 hängt alle Geräte hinter PCIe-Root-Ports, die SeaBIOS nicht enumeriert -
  # der Gast sähe dann *kein einziges* virtio-Gerät, weder NIC noch Disk. Talos
  # bootet zwar von der SATA-CD in den Maintenance-Mode, bleibt aber ohne Netz,
  # und der Config-Apply läuft in "no route to host". Deshalb q35 mit UEFI.
  #
  # Welche Firmware genau, entscheidet local.firmware: entweder libvirt sucht
  # sie selbst aus, oder es stehen feste Pfade drin (Unraid, siehe efi_loader).
  #
  os = merge({
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"

    # Reihenfolge ist Absicht: Bei leerer Disk fällt die Firmware auf die ISO
    # zurück (Maintenance-Mode). Nach der Installation bootet die VM von Disk,
    # obwohl die ISO angehängt bleibt.
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
        # cache und io sind hier nicht optional, auch wenn libvirt ohne sie
        # startet.
        #
        # Ohne `cache` nimmt QEMU writeback und legt jeden Block zusätzlich in
        # den Page-Cache des Hosts. Der Gast cacht denselben Block bereits
        # selbst - der Speicher der VM wird also faktisch zweimal gehalten, und
        # zwar auf einem Host mit 16 GB und ohne Swap. Genau dieser doppelte
        # Cache war schon einmal der Auslöser dafür, dass kswapd0 dauerhaft lief
        # und Unraid den Kernel-Modul-Squashfs (/boot/bzmodules) laufend vom
        # USB-Stick nachladen musste - 70 % iowait bei 6 % User-CPU.
        #
        # `none` gibt den Cache dem Gast allein (O_DIRECT). Für etcd ist das
        # ohnehin richtig: Es will wissen, wann ein fsync wirklich auf dem
        # Medium ist, und eine Cache-Schicht, die das beschönigt, ist bei einem
        # Stromausfall genau die, die die Datenbank zerlegt.
        #
        # `native` nutzt Linux-AIO statt eines Thread-Pools und setzt O_DIRECT
        # voraus - passt also nur zusammen mit cache = "none".
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

    # Talos loggt Boot und Installation auf die serielle Konsole. Da es kein SSH
    # und keine Shell gibt, ist das neben talosctl der einzige Weg, einem
    # fehlgeschlagenen Boot zuzusehen:
    #   virsh -c qemu+ssh://root@<unraid>/system console talos-cp1
    #
    # Bewusst ohne `source`: libvirt legt einen Chardev ohne Typangabe als
    # `pty` an, und genau das wird gebraucht.
    #
    # Der naheliegende Weg führt hier nicht hin. Ein `type = "pty"` neben
    # `target` - so steht es in vm/talos und vm/talos-test - ist keine Zeile,
    # die etwas tut: Das Schema dieses Providers kennt bei serials/consoles gar
    # kein `type`, und Terraform verwirft unbekannte Schlüssel in
    # objekttypisierten Attributen stillschweigend. Der Plan zeigt dann
    # `serials = [{}]`, ohne zu murren.
    #
    # Den Typ explizit zu setzen, ginge über `source`, das ihn als
    # diskriminierte Union führt (pty, file, tcp, unix, ...). Nur verlangt der
    # Provider dort `pty.path` als Pflichtfeld - den Pfad des Host-seitigen
    # Pseudo-Terminals, den libvirt erst zur Laufzeit vergibt. Also weglassen
    # und den Default nehmen.
    #
    # Gegenprobe am laufenden System, die auch zeigt, dass es wirklich pty ist:
    #   virsh -c qemu+ssh://root@<unraid>/system dumpxml talos-cp1 | grep -A2 '<serial'
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
  }

  running = true

  #
  # Wechselt die Boot-ISO, muss die VM neu entstehen.
  #
  # Ohne das ändert sich am Domain-XML nur der Dateiname des CD-Laufwerks - ein
  # In-Place-Update, das libvirt an einer laufenden Maschine als Medienwechsel
  # ausführt. Die VM läuft dabei weiter mit dem alten Kernel: Alles, was im
  # Image steckt (Extensions, Kernel-Parameter), wirkt erst beim nächsten
  # Neustart und damit scheinbar gar nicht.
  #
  # Für Talos-Upgrades ist das der falsche Weg - die laufen über
  # `talosctl upgrade`. Hier geht es um den Fall davor: eine geänderte
  # Schematic, bevor der Cluster überhaupt steht.
  #
  lifecycle {
    replace_triggered_by = [libvirt_volume.talos_iso]
  }
}

# =====================================================================
# Cluster
# =====================================================================

#
# Erzeugt die komplette Cluster-PKI (etcd-, Kubernetes- und Talos-CAs,
# Bootstrap-Token, Verschlüsselungs-Secrets).
#
# ACHTUNG: Diese Secrets liegen im Terraform-State. Der State ist per
# .gitignore ausgeschlossen und gleichbedeutend mit Cluster-Admin - er darf das
# lokale Dateisystem nicht unverschlüsselt verlassen.
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

    # Muss nach node.yaml.tftpl kommen: Der setzt den Hostnamen, dieser räumt
    # das von Talos erzeugte HostnameConfig-Dokument weg, das sonst kollidiert.
    file("${path.module}/patches/hostname.yaml"),

    templatefile("${path.module}/patches/cluster.yaml.tftpl", {
      pod_subnet     = var.pod_subnet
      service_subnet = var.service_subnet
    }),
  ]
}

#
# Überträgt die Config an den Node im Maintenance-Mode. Talos installiert sich
# daraufhin auf die Disk und rebootet. Der Provider wartet, bis der Node über
# die Maintenance-API erreichbar ist - der ISO-Boot dauert ein bis zwei Minuten.
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
# Blockiert, bis Control Plane und Node tatsächlich gesund sind. Damit schlägt
# `terraform apply` fehl, statt einen halb fertigen Cluster als Erfolg zu
# melden. Zum `count` siehe wait_for_health in variables.tf - er ist der
# Notausgang für destroy- und Reparaturläufe.
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
# weiterer Handgriff nötig ist. Beide Dateien sind Zugangsdaten mit vollem
# Cluster-Zugriff und stehen in .gitignore.
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
