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

output "status_commands" {
  description = "Zum Prüfen nach dem Anlegen des Secrets."
  value       = <<-EOT
    kubectl -n ${var.namespace} get fluxinstance flux
    kubectl -n ${var.namespace} get gitrepositories,kustomizations
    kubectl -n ${var.namespace} get pods

    Beweis, dass die Entschluesselung laeuft - erwartet wird "entschluesselt",
    nicht ENC[AES256_GCM,...]:

      kubectl -n ${var.namespace} get secret sops-smoketest \
        -o jsonpath='{.data.probe}' | base64 -d; echo
  EOT
}
