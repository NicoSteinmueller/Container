variable "libvirt_uri" {
  description = "Libvirt URI auf dem Host"
  type        = string
  default     = "qemu:///system"
}

variable "storage_pool" {
  description = "Libvirt Storage-Pool fuer Volumes"
  type        = string
  default     = "default"
}

variable "network_name" {
  description = "Libvirt Netzwerkname (z. B. default)"
  type        = string
  default     = "default"
}

variable "ubuntu_image_url" {
  description = "URL des Ubuntu Cloud Images"
  type        = string
  default     = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}

variable "vm_name" {
  description = "Name der VM"
  type        = string
  default     = "ubuntu-server"
}

variable "vm_user" {
  description = "Linux Benutzer, der per Cloud-Init erstellt wird"
  type        = string
  default     = "nico"
}

variable "ssh_public_key_path" {
  description = "Pfad zum oeffentlichen SSH Key des Hosts"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "timezone" {
  description = "Zeitzone der VM"
  type        = string
  default     = "Europe/Berlin"
}

variable "memory_mb" {
  description = "RAM in MB"
  type        = number
  default     = 4096
}

variable "vcpu_count" {
  description = "Anzahl vCPUs"
  type        = number
  default     = 2
}

# 30 GiB
variable "root_disk_size_bytes" {
  description = "Groesse der Root-Disk in Bytes"
  type        = number
  default     = 32212254720
}

