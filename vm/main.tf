terraform {
  required_version = ">= 1.5.0"

  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.9"
    }
  }
}

provider "libvirt" {
  uri = var.libvirt_uri
}

locals {
  ssh_public_key      = trimspace(file(pathexpand(var.ssh_public_key_path)))
  cloud_init_user_data = templatefile("${path.module}/cloud_init.cfg", {
    hostname       = var.vm_name
    username       = var.vm_user
    ssh_public_key = local.ssh_public_key
    timezone       = var.timezone
  })
}

resource "libvirt_volume" "ubuntu_image" {
  name   = "${var.vm_name}-ubuntu-base.qcow2"
  pool   = var.storage_pool
  source = var.ubuntu_image_url
  format = "qcow2"
}

resource "libvirt_volume" "vm_disk" {
  name           = "${var.vm_name}.qcow2"
  pool           = var.storage_pool
  base_volume_id = libvirt_volume.ubuntu_image.id
  size           = var.root_disk_size_bytes
  format         = "qcow2"
}

resource "libvirt_cloudinit_disk" "cloud_init" {
  name      = "${var.vm_name}-cloudinit.iso"
  pool      = var.storage_pool
  user_data = local.cloud_init_user_data
}

resource "libvirt_domain" "ubuntu_vm" {
  name       = var.vm_name
  memory     = var.memory_mb
  vcpu       = var.vcpu_count
  qemu_agent = true
  autostart  = true
  cloudinit  = libvirt_cloudinit_disk.cloud_init.id

  disk {
    volume_id = libvirt_volume.vm_disk.id
  }

  network_interface {
    network_name   = var.network_name
    wait_for_lease = true
  }

  console {
    type        = "pty"
    target_type = "serial"
    target_port = "0"
  }

  graphics {
    type        = "spice"
    listen_type = "none"
    autoport    = true
  }
}

