output "ssh_target" {
  description = "SSH-Ziel im Format user@host. Nur vom Hypervisor-Host aus erreichbar - die Skripte in verify/ und scripts/ lesen diesen Wert."
  value       = "${var.admin_user}@${var.mgmt_ip}"
}

output "mgmt_ssh" {
  description = "Fertiger SSH-Aufruf."
  value       = "ssh ${var.admin_user}@${var.mgmt_ip}"
}

output "wan_ip" {
  description = "Ziel der Fritzbox-Portfreigabe (443 tcp+udp) und der Split-DNS-Einträge in AdGuard."
  value       = var.wan_ip
}

output "wan_gateway" {
  description = "Default-Gateway der Firewall (Fritzbox)."
  value       = var.wan_gateway
}

output "lan_cidr" {
  description = "Heimnetz - aus DMZ und Cluster gesperrt."
  value       = var.lan_cidr
}

output "dmz" {
  description = "DMZ-Segment für die Edge-VM. Kein DHCP - Gäste statisch adressieren."
  value = {
    network = libvirt_network.dmz.name
    bridge  = var.dmz_bridge
    cidr    = var.dmz_cidr
    gateway = var.dmz_gateway_ip
    edge_ip = var.edge_ip
  }
}

output "cluster" {
  description = "Cluster-Segment für die Talos-Nodes. Kein DHCP - Gäste statisch adressieren."
  value = {
    network    = libvirt_network.cluster.name
    bridge     = var.cluster_bridge
    cidr       = var.cluster_cidr
    gateway    = var.cluster_gateway_ip
    ingress_ip = var.cluster_ingress_ip
  }
}

output "nftables_ruleset" {
  description = <<-EOT
    Gerenderter Regelsatz. Referenz für verify/assert-ruleset.sh und Quelle für
    scripts/push-ruleset.sh:

      terraform output -raw nftables_ruleset
  EOT
  value       = local.nftables_ruleset
}

output "alpine_image_url" {
  description = "Verwendetes Cloud-Image - zur Kontrolle nach einem Renovate-PR."
  value       = local.alpine_url
}
