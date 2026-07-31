output "node_ip" {
  description = "IP des Control-Plane-Nodes."
  value       = var.node_ip
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
  description = "Installer-Image für `talosctl upgrade --image ...`."
  value       = data.talos_image_factory_urls.this.urls.installer
}

output "talosconfig" {
  description = "Client-Config für talosctl. Schreiben mit: terraform output -raw talosconfig > talosconfig"
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}

output "kubeconfig" {
  description = "kubeconfig für kubectl. Schreiben mit: terraform output -raw kubeconfig > kubeconfig"
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
}
