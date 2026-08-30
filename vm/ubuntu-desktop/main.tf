terraform {
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "0.9.9"
    }
  }
}

provider "libvirt" {
  uri = "qemu:///system"
}

#
# Ubuntu 24.04 Cloud Image
#
resource "libvirt_volume" "ubuntu_base" {
  name = "ubuntu-24.04-base.qcow2"
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

#
# Writable overlay
#
resource "libvirt_volume" "ubuntu_disk" {
  name = "ubuntu-desktop.qcow2"
  pool = "default"

  target = {
    format = {
      type = "qcow2"
    }
  }

  capacity = 25 * 1024 * 1024 * 1024 # 25 GB

  backing_store = {
    path = libvirt_volume.ubuntu_base.path

    format = {
      type = "qcow2"
    }
  }
}

#
# Cloud-init
#
resource "libvirt_cloudinit_disk" "ubuntu_seed" {
  name = "ubuntu-cloudinit"

  user_data = file("${path.module}/cloud_init.cfg")

  meta_data = yamlencode({
    instance_id    = "ubuntu-desktop"
    local_hostname = "ubuntu-desktop"
  })

  network_config = <<EOF
version: 2
ethernets:
  eth0:
    match:
      name: "en*"
    dhcp4: true
EOF
}

#
# Upload ISO
#
resource "libvirt_volume" "ubuntu_seed_volume" {
  name = "ubuntu-cloudinit.iso"
  pool = "default"
  target = {
    format = {
      type = "iso"
    }
  }
  create = {
    content = {
      url = libvirt_cloudinit_disk.ubuntu_seed.path
    }
  }
}

#
# VM
#
resource "libvirt_domain" "ubuntu" {
  name        = "ubuntu-24.04-desktop"
  memory      = 4096
  memory_unit = "MiB"
  vcpu        = 2
  type        = "kvm"

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "pc"
  }

  devices = {
    disks = [
      {
        source = {
          volume = {
            pool   = libvirt_volume.ubuntu_disk.pool
            volume = libvirt_volume.ubuntu_disk.name
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
            pool   = libvirt_volume.ubuntu_seed_volume.pool
            volume = libvirt_volume.ubuntu_seed_volume.name
          }
        }

        target = {
          dev = "sdb"
          bus = "ide"
        }
      }
    ]

    interfaces = [
      {
        type = "network"
        mac = {
          address = "52:54:00:12:34:56"
        }
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

    graphics = [
      {
        spice = {
          auto_port = true
          listen    = "127.0.0.1"
        }
      }
    ]

    # NEU: Die virtuelle Grafikkarte, die das Bild für Spice rendert
    videos = [
      {
        model = {
          type = "virtio"
          heads = 1
          primary = "yes"
        }
      }
    ]

    # NEU: Der zugrundeliegende serielle Port, den die Konsole zwingend braucht
    serials = [
      {
        type = "pty"
      }
    ]

    # Korrigiert zu Mehrzahl: consoles
    consoles = [
      {
        type = "pty"
        target = {
          port = 0
          type = "serial"
        }
      }
    ]
  }

  running = true
}
