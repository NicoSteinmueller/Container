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
# Drei Secrets legt main.tf leer an - die Werte gehen nicht durch den State.
# Dieser Output beschreibt nur den Weg, sie nachzutragen.
#
output "bootstrap" {
  description = "Ohne diese drei Werte bleiben GitRepository und Kustomization \"Unknown\"."
  value       = <<-EOT
    Das Skript fragt die drei Werte nacheinander ab (verdeckte Eingabe) und
    traegt sie ein. Leere Eingabe laesst das jeweilige Secret unveraendert:

      ../../tools/sops-bootstrap

      ${var.sops_secret_name}             die Zeile AGE-SECRET-KEY-1... des Arbeitsschluessels
      ${var.secrets_git_secret_name}   Gitea-Benutzer und Token, Leserecht auf homelab-secrets
      ${var.git_secret_name}          GitHub-PAT, optional - das Repo ist oeffentlich

    Von Hand geht es auch, etwa aus einer anderen Umgebung heraus:

      kubectl -n ${var.namespace} patch secret ${var.secrets_git_secret_name} --type=merge \
        -p '{"stringData":{"username":"<gitea-user>","password":"<Gitea PAT, Repo: Read>"}}'

      kubectl -n ${var.namespace} patch secret ${var.git_secret_name} --type=merge \
        -p '{"stringData":{"username":"git","password":"<GitHub PAT, Contents: Read>"}}'

    Der age-Schluessel gehoert dabei nicht auf die Kommandozeile - er stuende in
    der Prozessliste und in der Shell-Historie. Fuer ihn:

      kubectl -n ${var.namespace} patch secret ${var.sops_secret_name} --type=merge \
        --patch-file /dev/stdin

    und das Patch-Dokument ueber stdin nachreichen:

      {"stringData":{"identity.agekey":"AGE-SECRET-KEY-1..."}}

    Der abgeleitete Public Key muss in .sops.yaml als Empfaenger stehen -
    sops-bootstrap zeigt ihn nach dem Setzen an. Stimmt er nicht ueberein,
    wurde gegen einen Schluessel verschluesselt, den der Cluster nicht hat.

    Ist der Arbeitsschluessel verloren, ist der Recovery-Schluessel der einzige
    Weg an die vorhandenen Secrets - siehe homelab-secrets/README.md.
  EOT
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
