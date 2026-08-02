output "node_name" {
  description = "Name der libvirt-Domain. Serielle Konsole: virsh -c <uri> console <name>."
  value       = local.node_name
}

output "lan_ip" {
  description = "Adresse des Nodes im Heimnetz. Talos-API, Kubernetes-API und ingress-internal."
  value       = var.lan_ip
}

output "node_dmz_ip" {
  description = <<-EOT
    Adresse des Nodes im DMZ-Segment. Muss in vm/edge als cluster_ingress_ip
    (und damit auch als step_ca_ip) eingetragen sein - dort hängt der gesamte
    Weg von außen nach innen daran.
  EOT
  value       = var.node_dmz_ip
}

output "cluster_endpoint" {
  description = "Kubernetes-API-Endpoint."
  value       = local.cluster_endpoint
}

output "kubeconfig_path" {
  description = "Pfad der geschriebenen kubeconfig. Genau dieser Wert gehört in k8s/platform als kubeconfig_path."
  value       = local_sensitive_file.kubeconfig.filename
}

output "talosconfig_path" {
  description = "Pfad der geschriebenen talosconfig. Verwendung: talosctl --talosconfig <pfad> -n <lan_ip> ..."
  value       = local_sensitive_file.talosconfig.filename
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

output "ingress_firewall_enforced" {
  description = "Zeigt, ob die Ingress-Firewall auf block steht (Zielzustand) oder noch auf accept (Inbetriebnahme)."
  value       = var.ingress_firewall_enforced
}

output "talosconfig" {
  description = "Client-Config für talosctl als Wert. Datei liegt bereits unter talosconfig_path."
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}

output "kubeconfig" {
  description = "kubeconfig als Wert. Datei liegt bereits unter kubeconfig_path."
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
}

output "naechste_schritte" {
  description = "Die Reihenfolge, in der der Cluster scharf wird - mit den konkreten Adressen dieses Stands."
  value       = <<-EOT
    1. Gesundheit prüfen:
         export TALOSCONFIG=${abspath(path.module)}/talosconfig
         export KUBECONFIG=${abspath(path.module)}/kubeconfig
         talosctl -n ${var.lan_ip} health
         kubectl get nodes -o wide          # Ready, INTERNAL-IP ${var.lan_ip}

    2. Beine gegenprüfen (verify/assert-cluster.sh):
         talosctl -n ${var.lan_ip} get addresses
         ${var.lan_ip} auf dem LAN-Bein, ${var.node_dmz_ip} auf dem DMZ-Bein

    3. Cluster ausstatten:
         cd ../../k8s/platform
         terraform apply   # kubeconfig_path = ${abspath(path.module)}/kubeconfig

    4. In vm/edge eintragen und dort erneut anwenden:
         cluster_ingress_ip = "${var.node_dmz_ip}"
         step_ca_url        = "https://${var.node_dmz_ip}:${var.step_ca_port}"
         step_ca_fingerprint = <Ausgabe von k8s/platform: step_ca_fingerprint_cmd>

    5. Erst danach die Fritzbox-Freigabe auf die Edge-VM setzen.
  EOT
}
