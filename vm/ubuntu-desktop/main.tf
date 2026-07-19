terraform {
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "0.9.8" # Nutzt die aktuelle Version des Providers
    }
  }
}

provider "libvirt" {
  uri = "qemu:///system"
}

# 1. Ubuntu Cloud Image als Basis herunterladen
resource "libvirt_volume" "ubuntu_base" {
  name = "ubuntu-24.04.qcow2"
  pool = "default"
  target = {
    format = {
      type = "qcow2"
    }
  }

  create = {
    content = {
      url = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
    }
  }

}

# 2. Eigene Festplatte für die VM aus der Basis erstellen (Größe anpassen!)
resource "libvirt_volume" "ubuntu_disk" {
  name     = "ubuntu-desktop-root.qcow2"
  pool     = "default"
  capacity = 25 * 1024 * 1024 * 1024 # 25 GB Speicherplatz
  target = {
    format = {
      type = "qcow2"
    }
  }
  backing_store = {
    path = libvirt_volume.ubuntu_base.path
    format = {
      type = "qcow2"
    }
  }
}

# 3. Cloud-Init Konfiguration einbinden
resource "libvirt_cloudinit_disk" "ubuntu_seed" {
  name      = "ubuntu-cloudinit"
  user_data = file("${path.module}/cloud_init.cfg")
  meta_data = yamlencode({
    instance_id    = "ubuntu-desktop"
    local_hostname = "ubuntu-desktop"
  })
  network_config = <<-EOF
    version: 2
    ethernets:
      eth0:
        dhcp4: true
    EOF
}

# replace cloud-init ISO into the pool
resource "libvirt_volume" "ubuntu_seed_volume" {
  name = "ubuntu-cloudinit.iso"
  pool = "default"

  create = {
    content = {
      url = libvirt_cloudinit_disk.ubuntu_seed.path
    }
  }
}

# 4. Die eigentliche VM definieren
resource "libvirt_domain" "ubuntu_desktop_vm" {
  name        = "ubuntu-24.04-desktop"
  memory      = 4096
  memory_unit = "MiB"
  vcpu        = 2
  type        = "kvm"

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"
    boot_devices = [
      {
        dev = "hd"
      }
    ]
  }

  devices = {
    disks = [
      {
        source = {
          volume = {
            pool = libvirt_volume.ubuntu_disk.pool
            volume = libvirt_volume.ubuntu_disk.name
          }
        }
        target = {
          dev = "vda"
          bus = "virtio"
        }
      },
      {
        device = "cdrom"
        source = {
            volume = {
                pool = libvirt_volume.ubuntu_seed_volume.pool
                volume = libvirt_volume.ubuntu_seed_volume.name
            }
        }
        target = {
          dev = "sda"
            bus = "sata"
        }
      }
    ]
    interfaces = [
      {
        type = "network"
        model = {
          type = "virtio"
        }
        source = {
          network = {
            network = "default"
          }
        }
      }
    ]

    graphics = [{
      spice = {
        auto_port = true
        listen    = "127.0.0.1"
      }
    }]
  }

  running = true
}
