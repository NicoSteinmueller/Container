output "vm_name" {
  description = "Name der erstellten VM"
  value       = libvirt_domain.ubuntu_vm.name
}

output "vm_id" {
  description = "Libvirt Domain ID"
  value       = libvirt_domain.ubuntu_vm.id
}

output "cloudinit_disk" {
  description = "Cloud-init ISO path"
  value       = libvirt_cloudinit_disk.cloud_init.id
}
