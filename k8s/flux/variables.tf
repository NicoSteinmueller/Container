variable "kubeconfig_path" {
  description = <<-EOT
    kubeconfig des Zielclusters. Voreingestellt ist die Datei, die
    vm/talos-simple nach einem erfolgreichen `terraform apply` schreibt.

    Sie ist gleichbedeutend mit Cluster-Admin und steht dort in .gitignore.
  EOT
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

variable "flux_version" {
  description = <<-EOT
    Flux-Distribution, die die FluxInstance einrichtet. "2.9.x" statt einer
    exakten Version - der Operator zieht innerhalb der Minor-Version
    automatisch Patch-Releases nach, ohne dass variables.tf dafür geändert
    werden muss.
  EOT
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
  default     = "kubernetes-try"
}

variable "sync_path" {
  description = <<-EOT
    Pfad im Repo, den die FluxInstance als Wurzel-Kustomization anwendet.

    Zeigt auf k8s/flux/clusters/talos-cp1 - aktuell absichtlich leer (nur ein
    README). Der nächste Schritt ist, dort eine Kustomization abzulegen, die
    z.B. k8s/whoami einbindet - siehe README.
  EOT
  type        = string
  default     = "k8s/flux/clusters/talos-cp1"
}

variable "git_secret_name" {
  description = <<-EOT
    Name des Secrets mit den Git-Zugangsdaten (Keys: username, password).

    Wird von diesem Modul bewusst NICHT angelegt - Geheimnisse kommen nicht
    aus Terraform-State, dieselbe Regel wie bei step-ca und den
    Headlamp-Tokens. Der Befehl zum Anlegen steht im Output
    `bootstrap_secret`.
  EOT
  type        = string
  default     = "flux-git-auth"
}

#
# Der Weg zur Flux-Status-Seite
#
variable "service_type" {
  description = <<-EOT
    Wie die Flux-Status-Seite (Port 9080) erreichbar ist:

      ClusterIP  - gar nicht von außen. Zugang über

                     kubectl -n <namespace> port-forward svc/flux-operator 9080:9080

      NodePort   - erreichbar unter http://<node_ip>:<node_port> aus dem
                   Heimnetz, ohne kubectl.

    Anders als bei Headlamp verlangt die Oberfläche standardmäßig KEIN Token -
    NodePort bedeutet hier also: jeder im Heimnetz sieht den GitOps-Zustand
    ohne jede Anmeldung. Sie zeigt dafür weder Secrets noch ConfigMaps.
    Abwägung ausführlich im README.
  EOT
  type        = string
  default     = "NodePort"

  validation {
    condition     = contains(["ClusterIP", "NodePort"], var.service_type)
    error_message = "service_type muss ClusterIP oder NodePort sein."
  }
}

variable "node_port" {
  description = "Port auf dem Node, nur bei service_type = \"NodePort\". Muss im NodePort-Bereich liegen (30000-32767)."
  type        = number
  default     = 30081

  validation {
    condition     = var.node_port >= 30000 && var.node_port <= 32767
    error_message = "node_port muss zwischen 30000 und 32767 liegen."
  }
}
