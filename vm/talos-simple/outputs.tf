output "node_ip" {
  description = "Feste Adresse des Nodes im Heimnetz. Ziel für talosctl und kubectl."
  value       = var.lan_ip
}

output "node_name" {
  description = "Hostname des Nodes - zugleich der Kubernetes-Node-Name."
  value       = local.node_name
}

output "cluster_endpoint" {
  description = "Kubernetes-API-Endpoint."
  value       = local.cluster_endpoint
}

output "schematic_id" {
  description = <<-EOT
    Image-Factory-Schematic-ID. Bei jedem Talos-Upgrade mit exakt dieser ID
    arbeiten, sonst gehen die System-Extensions verloren.
  EOT
  value       = talos_image_factory_schematic.this.id
}

output "installer_image" {
  description = "Installer-Image für `talosctl upgrade --image ...`. Enthält bereits die richtige Schematic-ID."
  value       = data.talos_image_factory_urls.this.urls.installer
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
  description = "kubeconfig als Text. Wird bereits als Datei geschrieben - dieser Output ist für den Fall, dass sie woanders gebraucht wird."
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
}

output "talosconfig" {
  description = "talosconfig als Text."
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}
