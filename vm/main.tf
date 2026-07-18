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
  ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))
  cloud_init_user_data = templatefile("${path.module}/cloud_init.cfg", {
    hostname       = var.vm_name
    username       = var.vm_user
    ssh_public_key = local.ssh_public_key
    timezone       = var.timezone
  })
  cloud_init_meta_data = jsonencode({
    instance-id    = var.vm_name
    local-hostname = var.vm_name
  })
}

# Cloud-init disk for VM initialization
resource "libvirt_cloudinit_disk" "cloud_init" {
  name      = "${var.vm_name}-cloudinit.iso"
  meta_data = local.cloud_init_meta_data
  user_data = local.cloud_init_user_data
}

# Ubuntu VM domain
# Note: This requires the Ubuntu image to already exist at the specified path
# Download it manually: wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img -O /var/lib/libvirt/images/ubuntu-base.qcow2
resource "libvirt_domain" "ubuntu_vm" {
  name      = var.vm_name
  memory    = var.memory_mb
  vcpu      = var.vcpu_count
  type      = "kvm"
  autostart = false

  # OS configuration for HVM virtualization
  os = {
    type = "hvm"
  }
}

