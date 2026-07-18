terraform {
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "0.8.1" # Nutzt die aktuelle Version des Providers
    }
  }
}

provider "libvirt" {
  uri = "qemu:///system"
}

# 1. Ubuntu Cloud Image als Basis herunterladen
resource "libvirt_volume" "ubuntu_base" {
  name   = "ubuntu-desktop-base.qcow2"
  pool   = "default"
  source = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img" # Ubuntu 24.04 LTS
  format = "qcow2"
}

# 2. Eigene Festplatte für die VM aus der Basis erstellen (Größe anpassen!)
resource "libvirt_volume" "vm_disk" {
  name           = "ubuntu-desktop-root.qcow2"
  base_volume_id = libvirt_volume.ubuntu_base.id
  pool           = "default"
  size           = 25 * 1024 * 1024 * 1024 # 25 GB Speicherplatz
  format         = "qcow2"
}

# 3. Cloud-Init Konfiguration einbinden
resource "libvirt_cloudinit_disk" "commoninit" {
  name      = "commoninit.iso"
  user_data = file("${path.module}/cloud_init.cfg")
  pool      = "default"
}

# 4. Die eigentliche VM definieren
resource "libvirt_domain" "ubuntu_desktop_vm" {
  name   = "ubuntu-desktop"
  memory = "4096" # 4 GB RAM
  vcpu   = 2      # 2 CPU Kerne

  cloudinit = libvirt_cloudinit_disk.commoninit.id

  # Grafikkarte und Display aktivieren, damit du ein Bild siehst
  graphics {
    type        = "spice"
    listen_type = "address"
    autoport    = true
  }

  video {
    type = "virtio"
  }

  network_interface {
    network_name = "default" # Standard KVM NAT-Netzwerk
  }

  disk {
    volume_id = libvirt_volume.vm_disk.id
  }

  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }
}