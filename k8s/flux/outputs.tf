output "namespace" {
  description = "Namespace von Flux Operator und den Flux-Controllern."
  value       = kubernetes_namespace.flux_system.metadata[0].name
}

output "access" {
  description = "Der Weg zur Flux-Status-Seite - abhängig von service_type."
  value = var.service_type == "NodePort" ? (
    "http://<node_ip>:${var.node_port}  (kein Login, siehe README zur Abwägung)"
    ) : (
    "kubectl -n ${var.namespace} port-forward svc/flux-operator 9080:9080  ->  http://localhost:9080"
  )
}

#
# Das Secret wird leer angelegt (main.tf) - dieser Output beschreibt nur den
# Weg, die Werte nachzutragen.
#
output "fill_secret" {
  description = "Ohne echte Werte im Secret bleibt die GitRepository-Quelle \"Unknown\"."
  value       = <<-EOT
    Eintragen per kubectl (braucht Zugriff auf das kubeconfig aus
    var.kubeconfig_path):

      kubectl -n ${var.namespace} patch secret ${var.git_secret_name} --type=merge \
        -p '{"stringData":{"username":"git","password":"<GitHub PAT, fein-scoped auf genau dieses Repo, zunächst nur Contents: Read>"}}'

    Alternativ über Headlamp, wenn gerade kein kubeconfig zur Hand ist:

      1. Admin-Token holen: kubectl -n headlamp create token headlamp-admin --duration=1h
      2. In Headlamp: Secrets -> Namespace ${var.namespace} -> ${var.git_secret_name} -> Edit
      3. username = git, password = <GitHub PAT, siehe oben>
  EOT
}

output "status_commands" {
  description = "Zum Prüfen nach dem Anlegen des Secrets."
  value       = <<-EOT
    kubectl -n ${var.namespace} get fluxinstance flux
    kubectl -n ${var.namespace} get gitrepositories,kustomizations
    kubectl -n ${var.namespace} get pods
  EOT
}
