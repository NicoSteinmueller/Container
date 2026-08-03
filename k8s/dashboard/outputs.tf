output "namespace" {
  description = "Namespace des Dashboards."
  value       = kubernetes_namespace.headlamp.metadata[0].name
}

output "access" {
  description = <<-EOT
    Der Weg zur Oberfläche - abhängig von service_type. Bei NodePort steht die
    Adresse des Nodes im Output `node_ip` von vm/talos-simple.
  EOT
  value = var.service_type == "NodePort" ? (
    "http://<node_ip>:${var.node_port}  (unverschlüsseltes HTTP im LAN)"
    ) : (
    "kubectl -n ${var.namespace} port-forward svc/headlamp 8080:80  ->  http://localhost:8080"
  )
}

#
# Die Anmeldung selbst. Ohne eines dieser Token zeigt die Oberfläche nichts -
# das ist der Grund, warum sie ohne TLS-Vorbau überhaupt vertretbar ist.
#
output "read_token_command" {
  description = "Token zum Lesen. Läuft nach der angegebenen Dauer ab, ohne dass jemand daran denken muss."
  value       = "kubectl -n ${var.namespace} create token ${local.service_account} --duration=8h"
}

output "admin_token_command" {
  description = "Token mit cluster-admin, für Änderungen im Dashboard. Nur vorhanden, wenn admin_service_account gesetzt ist."
  value = var.admin_service_account ? (
    "kubectl -n ${var.namespace} create token ${local.admin_service_account} --duration=1h"
    ) : (
    "admin_service_account = false - im Dashboard wird nur gelesen"
  )
}
