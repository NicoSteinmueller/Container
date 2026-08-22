variable "kubeconfig_path" {
  description = "kubeconfig des Zielclusters. Voreingestellt die Datei aus vm/talos-simple - Cluster-Admin, dort in .gitignore."
  type        = string
  default     = "../../vm/talos-simple/kubeconfig"
}

variable "namespace" {
  description = "Namespace für Flux Operator und die Flux-Controller."
  type        = string
  default     = "flux-system"
}

variable "flux_operator_chart_version" {
  description = "Chart-Version von flux-operator (ghcr.io/controlplaneio-fluxcd/charts)."
  type        = string
  default     = "0.57.0"
}

variable "flux_instance_chart_version" {
  description = <<-EOT
    Chart-Version von flux-instance - legt die FluxInstance an.

    Gleich halten mit flux_operator_chart_version: beide Charts kommen aus
    demselben Repo, sonst rendert das eine gegen ein fremdes CRD-Schema.
  EOT
  type        = string
  default     = "0.57.0"
}

variable "flux_version" {
  description = "Flux-Distribution der FluxInstance. \"2.9.x\": Patch-Releases zieht der Operator selbst nach."
  type        = string
  default     = "2.9.x"
}

#
# Git-Quelle
#
variable "git_url" {
  description = "Repo, das Flux beobachtet. HTTPS, weil der Zugang per PAT läuft (siehe git_secret_name)."
  type        = string
  default     = "https://github.com/NicoSteinmueller/Container.git"
}

variable "git_branch" {
  description = "Branch, den Flux synchronisiert."
  type        = string
  # TODO auf "main" umstellen, sobald das Repo umgestellt ist.
  default = "kubernetes-try"
}

variable "sync_path" {
  description = "Pfad im Repo, den die FluxInstance als Wurzel-Kustomization anwendet."
  type        = string
  default     = "k8s/flux/clusters/talos-cp1"
}

variable "git_secret_name" {
  description = <<-EOT
    Secret mit den Git-Zugangsdaten (Keys: username, password).

    Wird leer angelegt - die echten Werte gehen nicht durch Terraform-State.
    Befehl zum Befüllen: Output `fill_secret`.
  EOT
  type        = string
  default     = "flux-git-auth"
}

#
# Secrets - das zweite Repo und sein Schluessel
#
# Die Adresse des Repos steht nicht hier, sondern in
# clusters/talos-cp1/secrets.yaml: Sie ist Teil dessen, was Flux anwendet, und
# nicht Teil dessen, womit Terraform Flux einrichtet. Terraform legt hier nur
# die Gefaesse an, die vor dem ersten Sync existieren muessen.
#
variable "secrets_git_secret_name" {
  description = <<-EOT
    Secret mit den Gitea-Zugangsdaten fuer homelab-secrets (Keys: username,
    password).

    Wird leer angelegt und von Hand nachgetragen - der Befehl dafuer steht
    im README.
  EOT
  type        = string
  default     = "homelab-secrets-auth"
}

variable "sops_secret_name" {
  description = <<-EOT
    Secret mit dem privaten age-Schluessel (Key: identity.agekey).

    Damit entschluesselt kustomize-controller die Manifeste aus
    homelab-secrets. Wird leer angelegt und von Hand nachgetragen - der
    Befehl dafuer steht im README.
  EOT
  type        = string
  default     = "sops-age"
}

#
# Der Weg zur Flux-Status-Seite
#
variable "service_type" {
  description = <<-EOT
    Wie die Flux-Status-Seite (Port 9080) erreichbar ist:

      ClusterIP  - nur per port-forward svc/flux-operator 9080:9080
      NodePort   - http://<node_ip>:<node_port> aus dem Heimnetz

    Die Seite verlangt kein Token, zeigt aber weder Secrets noch ConfigMaps -
    NodePort heißt also: jeder im Heimnetz sieht den GitOps-Zustand. README.
  EOT
  type        = string
  default     = "NodePort"

  validation {
    condition     = contains(["ClusterIP", "NodePort"], var.service_type)
    error_message = "service_type muss ClusterIP oder NodePort sein."
  }
}

variable "web_source_cidrs" {
  description = <<-EOT
    Quellnetze, die bei service_type = "NodePort" auf die Status-Seite dürfen.

    Nötig, weil das flux-operator-Chart eine eigene NetworkPolicy mitbringt,
    die Port 9080 nur clusterinternen Identitäten öffnet. Ein Browser im
    Heimnetz ist für Cilium `world` und würde verworfen - siehe main.tf.

    Default sind die privaten Bereiche nach RFC 1918: Das konkrete Heimnetz
    steht nicht in diesem Repo, sondern in den tfvars, und dort gehört der
    Wert auch eingeengt. "0.0.0.0/0" wäre hier kein Sicherheitsgewinn und kein
    -verlust, solange der Node nur im LAN hängt - aber ein Router, der den Port
    weiterleitet, wäre dann ein Fehler ohne zweite Bremse.
  EOT
  type        = list(string)
  default     = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]

  validation {
    condition     = length(var.web_source_cidrs) > 0
    error_message = "Mindestens ein Quellnetz - eine leere Liste verwirft jeden Zugriff und die Seite wäre über den NodePort tot."
  }
}

variable "node_port" {
  description = "Port auf dem Node, nur bei service_type = \"NodePort\" (30000-32767)."
  type        = number
  default     = 30081

  validation {
    condition     = var.node_port >= 30000 && var.node_port <= 32767
    error_message = "node_port muss zwischen 30000 und 32767 liegen."
  }
}
