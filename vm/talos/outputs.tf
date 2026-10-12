output "nodes" {
  description = <<-EOT
    Je Node: Hostname (zugleich Kubernetes-Node-Name), feste Adresse, Rolle,
    Schematic-ID und Installer-Image. Bei jedem Talos-Upgrade mit exakt der
    Schematic-ID des Nodes arbeiten, sonst gehen seine System-Extensions
    verloren. nfs_tunnel_public_key gehört auf dem NFS-Server in den Peer des
    Nodes, null ohne nfs_tunnel.

      tf output -json nodes | jq -r .cp1.schematic_id
  EOT
  value = {
    for key, node in local.nodes : key => {
      name                  = node.name
      ip                    = node.lan_ip
      role                  = node.role
      schematic_id          = talos_image_factory_schematic.node[key].id
      installer_image       = data.talos_image_factory_urls.node[key].urls.installer
      nfs_tunnel_public_key = try(wireguard_asymmetric_key.nfs_tunnel[key].public_key, null)
    }
  }
}

output "cluster_endpoint" {
  description = "Kubernetes-API-Endpoint."
  value       = local.cluster_endpoint
}

output "kubeconfig_path" {
  description = "Pfad der geschriebenen kubeconfig."
  value       = local_sensitive_file.kubeconfig.filename
}

output "talosconfig_path" {
  description = "Pfad der geschriebenen talosconfig."
  value       = local_sensitive_file.talosconfig.filename
}

output "kubeconfig" {
  description = "kubeconfig als Text, falls sie woanders gebraucht wird - als Datei liegt sie bereits vor."
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
}

output "talosconfig" {
  description = "talosconfig als Text."
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}
