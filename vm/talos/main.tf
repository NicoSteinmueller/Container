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
      version = "0.9.9"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "0.12.0"
    }
    #
    # Nur für `data "helm_template"`: Cilium wird lokal gerendert und als
    # Inline-Manifest in die Machine-Config gelegt. Der Provider selbst fasst
    # keinen Cluster an - die eigentlichen Helm-Releases stehen als
    # HelmRelease in k8s/flux. (Das Modul spricht am Ende doch einmal mit dem
    # Cluster, siehe terraform_data.cilium_manifest_sync - aber über
    # talosctl, nicht über Helm.)
    #
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    #
    # Nur für das Schlüsselpaar des NFS-Tunnels. Der private Teil entsteht im
    # State und steht damit nirgends sonst.
    #
    wireguard = {
      source  = "ojford/wireguard"
      version = "0.4.1"
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

  #
  # Name des User-Volumes. Er bestimmt den Mountpfad in Talos
  # (/var/mnt/<name>) und muss deshalb mit nodePath in
  # k8s/flux/storage/local-path/HelmRelease.yaml uebereinstimmen.
  #
  local_path_volume = "local-path"

  #
  # Der Tunnel ist optional (nfs_tunnel = null im lokalen Testlauf). Eine
  # Liste statt eines leeren Patches, den der Provider ablehnen würde.
  #
  nfs_tunnel_patches = var.nfs_tunnel == null ? [] : [
    templatefile("${path.module}/patches/nfs-tunnel.yaml.tftpl", {
      private_key     = wireguard_asymmetric_key.nfs_tunnel[0].private_key
      node_port       = var.nfs_tunnel.node_port
      node_address    = var.nfs_tunnel.node_address
      host_public_key = var.nfs_tunnel.host_public_key
      host_endpoint   = var.nfs_tunnel.host_endpoint
      host_address    = var.nfs_tunnel.host_address
      host_ip         = split(":", var.nfs_tunnel.host_endpoint)[0]
    })
  ]

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

  #
  # Eine neue talos_version ändert Name und URL, darf die ISO aber nicht
  # ersetzen: Über replace_triggered_by in libvirt_domain.cp1 hinge daran die
  # VM, und ein Talos-Update baute sie neu, statt über `talosctl upgrade` zu
  # laufen. Gebraucht wird die ISO nur bis zur Installation, danach bootet die
  # VM von Disk - welche Version sie trägt, ist dann gleich.
  #
  # Neu entsteht sie nur, wenn sich die Schematic ändert. Bei einem Neuaufbau
  # nach destroy gelten Name und URL wie konfiguriert, also mit der aktuellen
  # talos_version.
  #
  lifecycle {
    ignore_changes       = [name, create]
    replace_triggered_by = [talos_image_factory_schematic.this.id]
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

#
# Zweite Disk: der lokale Speicher des Clusters. Talos legt darauf ein
# User-Volume an und mountet es nach /var/mnt/local-path (siehe den Patch
# weiter unten), local-path-provisioner macht daraus die Default-StorageClass.
#
# Getrennt von der System-Disk aus einem Grund, der nichts mit Geschwindigkeit
# zu tun hat - physisch ist es dieselbe SSD des Hypervisors. Es geht um die
# Kopplung: Auf der EPHEMERAL-Partition laegen Datenbanken sonst neben dem
# containerd-Image-Cache und den Logs. Laeuft sie voll, setzt das kubelet
# DiskPressure, evictet Pods und raeumt Images ab - und trifft dabei die
# Datenbank mit. Zwei Disks machen daraus zwei unabhaengige Ausfaelle.
#
# ACHTUNG, zweierlei:
#
#   - `capacity` zu aendern ersetzt das Volume. Terraform zerstoert es und legt
#     ein leeres an; der Inhalt ist weg. Deshalb grosszuegig waehlen, qcow2 ist
#     duenn alloziert (siehe vm_data_disk_gib).
#   - `tofu destroy` nimmt diese Disk mit. Sie ist kein Backup-Ziel und ersetzt
#     keines - ein Sicherungsweg aus dem Cluster heraus steht noch aus.
#
resource "libvirt_volume" "data" {
  name     = "${local.node_name}-data.qcow2"
  pool     = local.pool_name
  capacity = var.vm_data_disk_gib * 1024 * 1024 * 1024

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
        source = {
          volume = {
            pool   = libvirt_volume.data.pool
            volume = libvirt_volume.data.name
          }
        }
        target = {
          dev = "vdb"
          bus = "virtio"
        }
        # Gleiche Begruendung wie bei vda: der Gast soll den Cache allein haben.
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

    #
    # Das zweite Bein trägt nur public_ip, mit eigener MAC (siehe public_ip).
    # Der Kernel-Name hängt an der PCI-Position, die libvirt vergibt - nichts
    # hier verlässt sich darauf: Talos wählt per MAC, Cilium nimmt das Bein
    # selbst auf, weil es eine Adresse trägt.
    #
    interfaces = concat([
      {
        mac    = { address = var.node_mac }
        model  = { type = "virtio" }
        source = local.lan_source
      },
      ], var.public_ip == null ? [] : [
      {
        mac    = { address = var.public_mac }
        model  = { type = "virtio" }
        source = local.lan_source
      },
    ])

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
  # Die ISO wechselt nur mit der Schematic (siehe libvirt_volume.talos_iso),
  # nicht mit talos_version. Talos-Upgrades laufen über `talosctl upgrade`;
  # hier geht es um eine geänderte Schematic, bevor der Cluster steht.
  #
  lifecycle {
    replace_triggered_by = [libvirt_volume.talos_iso]
  }
}

# =====================================================================
# NFS-Tunnel
# =====================================================================

#
# Schlüsselpaar des Nodes für den WireGuard-Tunnel zum NFS-Server. Der
# öffentliche Teil geht als Output an den Host, der private nur in die
# Machine-Config.
#
resource "wireguard_asymmetric_key" "nfs_tunnel" {
  count = var.nfs_tunnel == null ? 0 : 1
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

  #
  # Die Version zählt nur beim Erzeugen. Danach würde ein Wechsel - jedenfalls
  # ein Downgrade, nachgemessen mit plan - die Secrets *ersetzen*: neue CAs,
  # neuer Bootstrap-Token, der laufende Cluster spräche mit niemandem mehr.
  #
  lifecycle {
    ignore_changes = [talos_version]
  }
}

data "talos_machine_configuration" "controlplane" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = "controlplane"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.machine_config_contract
  kubernetes_version = var.kubernetes_version

  #
  # flatten, weil local.nfs_tunnel_patches eine Liste ist - leer ohne Tunnel.
  #
  config_patches = flatten([
    # Was Talos selbst erzeugt und hier nicht passt. Muss vor node.yaml.tftpl
    # und cluster.yaml.tftpl kommen, die zwei der Dokumente neu anlegen.
    file("${path.module}/patches/defaults.yaml"),

    # Installationsziel und Installer-Image mit denselben Extensions wie die ISO.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "UnattendedInstallConfig"
      installer = {
        image = data.talos_image_factory_urls.this.urls.installer
      }
      provisioning = {
        diskSelector = {
          match = "disk.dev_path == \"${var.install_disk}\""
        }
        wipe = false
      }
    }),

    templatefile("${path.module}/patches/node.yaml.tftpl", {
      node_name   = local.node_name
      node_mac    = var.node_mac
      lan_ip      = var.lan_ip
      lan_cidr    = var.lan_cidr
      lan_prefix  = local.lan_prefix
      lan_gateway = var.lan_gateway
      dns_servers = var.dns_servers
      ntp_servers = var.ntp_servers
      public_ip   = var.public_ip
      public_mac  = var.public_mac
    }),

    #
    # Die zweite Disk als User-Volume. Eigenes Dokument, kein Merge in
    # v1alpha1.Config - deshalb ein eigener Patch.
    #
    templatefile("${path.module}/patches/uservolume.yaml.tftpl", {
      volume_name = local.local_path_volume
      # Der Selektor grenzt die Daten-Disk gegen die System-Disk ab und
      # braucht deren Pfad dafuer - eine Quelle, nicht zwei.
      install_disk = var.install_disk
    }),

    templatefile("${path.module}/patches/cluster.yaml.tftpl", {
      pod_subnet     = var.pod_subnet
      service_subnet = var.service_subnet
      lan_ip         = var.lan_ip
    }),

    #
    # Ingress-Firewall. Eigene Dokumente wie das User-Volume, kein Merge in
    # v1alpha1.Config.
    #
    # Ein Fehler hier sperrt die Talos-API aus. Terraform kann den
    # try-Modus nicht (der Provider kennt nur auto/reboot/no_reboot/staged),
    # deshalb gehoert ein Regelwechsel zuerst von Hand geprueft:
    #
    #   talosctl apply-config --mode=try --timeout=60s ...
    #
    # Talos nimmt die Aenderung dann nach einer Minute von selbst zurueck.
    # Der Ablauf steht in README.md unter "Ingress-Firewall".
    #
    templatefile("${path.module}/patches/firewall.yaml.tftpl", {
      admin_sources = var.admin_sources
      pod_subnet    = var.pod_subnet
      lan_cidr      = var.lan_cidr
    }),

    # WireGuard zum NFS-Server
    local.nfs_tunnel_patches,

    # Cilium. Muss der letzte Patch sein - nicht technisch, sondern damit die
    # lesbaren Patches oben nicht hinter dem gerenderten Chart verschwinden.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "KubeInlineManifestConfig"
      name       = "cilium"
      manifest   = data.helm_template.cilium.manifest
    }),
  ])
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

# =====================================================================
# Cilium-Manifest im Cluster nachziehen
# =====================================================================

#
# Warum es diesen Block braucht, obwohl das Chart doch in der Machine-Config
# steht: Talos legt Bootstrap-Manifeste beim Bootstrap an und fasst
# bestehende Objekte danach nicht mehr an. Das war bis v1.13 ausdruecklich so
# dokumentiert - fehlende Ressourcen anlegen, vorhandene unveraendert lassen,
# nie loeschen. Seit v1.13 macht Talos inventory-gestuetztes Server-Side-Apply
# und koennte es; verlassen kann man sich darauf nicht.
#
# `upgrade-k8s --to <bereits laufende Version>` ist der von Talos
# vorgesehene Weg dafuer. Gleiche Version heisst kein Versionssprung, nur ein
# Sync der Bootstrap-Manifeste.
#
# triggers_replace haengt an der gerenderten Zeichenkette, nicht an einer
# Versionsnummer: Der Sync laeuft, wenn sich Chart-Version ODER Values
# geaendert haben, und sonst nie. Beim allerersten Aufbau laeuft er einmal
# ueberfluessig mit - Talos hat die Manifeste da gerade selbst angelegt. Das
# kostet eine Minute und ist der Preis dafuer, hier keine Sonderregel zu
# haben.
#
# Bewusst talosctl und nicht `kubectl apply` des gerenderten Manifests: Ein
# Apply von aussen wuerde die Felder unter einem eigenen Field-Manager
# uebernehmen und Talos beim naechsten Mal im Weg stehen.
#
resource "terraform_data" "cilium_manifest_sync" {
  triggers_replace = [sha256(data.helm_template.cilium.manifest)]

  provisioner "local-exec" {
    command = join(" ", [
      "talosctl --talosconfig ${local_sensitive_file.talosconfig.filename}",
      "-n ${var.lan_ip}",
      "upgrade-k8s --to ${var.kubernetes_version}",
    ])
  }

  #
  # Erst wenn der Cluster steht - upgrade-k8s spricht mit der API.
  #
  depends_on = [
    data.talos_cluster_health.this,
    local_sensitive_file.talosconfig,
  ]
}
