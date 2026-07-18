output "vm_name" {
  description = "Name der erstellten VM"
  value       = libvirt_domain.ubuntu_vm.name
}

output "vm_id" {
  description = "Libvirt Domain ID"
  value       = libvirt_domain.ubuntu_vm.id
}

output "vm_ip_addresses" {
  description = "IP-Adressen der VM"
  value       = libvirt_domain.ubuntu_vm.network_interface[0].addresses
}

