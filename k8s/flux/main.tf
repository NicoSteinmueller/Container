#
# Flux (GitOps) für den Cluster aus vm/talos-simple - Push auf den Branch aus
# var.git_branch soll ausrollen, ohne dass jemand `kubectl apply` von Hand
# tippt. Dieselbe Idee, die Portainer bislang für die Compose-Stacks übernimmt.
#
# Warum Flux Operator und nicht `flux bootstrap` / terraform-provider-flux:
# Der klassische Weg committet die flux-system-Manifeste selbst ins Repo und
# braucht dafür Schreibrechte auf den Branch. Flux Operator dreht das um -
# eine einzige FluxInstance-Ressource beschreibt, welche Controller in
# welcher Version laufen sollen, und der Operator hält sie dort. Zusätzlich
# bringt er seit Flux 2.8 (GA Februar 2026) die einzige noch gepflegte
# In-Cluster-Oberfläche mit: Capacitor ist inzwischen ein lokales Binary
# (liest kubeconfig wie talosctl), Weave GitOps ist seit der
# Weaveworks-Schließung 2024 ohne neue Releases.
#
terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
  }
}

#
# Beide Provider sprechen über die kubeconfig, die vm/talos-simple schreibt.
# Ein Pfad, kein Wert aus einer anderen Ressource - siehe k8s/dashboard/main.tf
# für dieselbe Begründung.
#
provider "helm" {
  kubernetes {
    config_path = var.kubeconfig_path
  }
}

provider "kubernetes" {
  config_path = var.kubeconfig_path
}

# =====================================================================
# Namespace
# =====================================================================

#
# Bewusst ohne pod-security.kubernetes.io/enforce: restricted, anders als bei
# Headlamp in k8s/dashboard. Kustomize-controller und helm-controller müssen
# im Cluster anwenden dürfen, was im beobachteten Repo-Pfad steht - das ist
# der Kern von GitOps, keine übersehene Härtung. Die eigentliche Kontrolle
# liegt darin, wer auf var.git_branch schreiben darf, nicht in PodSecurity.
#
resource "kubernetes_namespace" "flux_system" {
  metadata {
    name = var.namespace
  }

  #
  # Die FluxInstance verwaltet flux-system als Teil ihrer eigenen
  # Root-Kustomization und markiert den Namespace dafür mit eigenen
  # Labels/Annotations (fluxcd.controlplane.io/*, kustomize.toolkit.fluxcd.io/*).
  # Ohne ignore_changes würde jeder terraform apply diese Markierungen wieder
  # entfernen und mit Flux um dasselbe Objekt konkurrieren.
  #
  lifecycle {
    ignore_changes = [metadata[0].labels, metadata[0].annotations]
  }
}

#
# Leer angelegt - die eigentlichen Werte (username, password = PAT) trägt
# niemand über Terraform ein. Ein echter PAT als Terraform-Variable stünde
# im Klartext in terraform.tfstate, genau das, was dieses Repo bei jedem
# anderen Geheimnis vermeidet (step-ca-Provisioner, CrowdSec-Bouncer-Keys,
# Headlamp-Tokens - siehe README).
#
# Stattdessen: Objekt existiert, damit die FluxInstance unten einen
# gültigen pullSecret-Namen referenzieren kann, und wird per
# `kubectl patch secret` nachträglich befüllt (siehe outputs.tf,
# fill_secret) - der Wert geht direkt an die API, nie durch
# Terraform-State. Headlamp (Admin-Token, siehe k8s/dashboard) geht
# alternativ, falls gerade kein kubeconfig zur Hand ist.
#
# ignore_changes ist deshalb kein Sicherheitsnetz gegen fremde Änderungen,
# sondern der Grund, warum das überhaupt funktioniert: Ohne die Zeile würde
# der nächste `terraform apply` data wieder auf die leeren Platzhalter aus
# diesem Manifest zurücksetzen und den per kubectl eingetragenen PAT
# überschreiben.
#
resource "kubernetes_secret" "flux_git_auth" {
  metadata {
    name      = var.git_secret_name
    namespace = kubernetes_namespace.flux_system.metadata[0].name
  }

  type = "Opaque"

  data = {
    username = ""
    password = ""
  }

  lifecycle {
    ignore_changes = [data]
  }
}

# =====================================================================
# Flux Operator
# =====================================================================

#
# Installiert nur den Operator und seine CRDs (u.a. FluxInstance). Die
# eigentlichen Flux-Controller kommen erst durch kubernetes_manifest.flux
# unten - der Operator liest die FluxInstance und richtet sie ein.
#
resource "helm_release" "flux_operator" {
  name       = "flux-operator"
  repository = "oci://ghcr.io/controlplaneio-fluxcd/charts"
  chart      = "flux-operator"
  version    = var.flux_operator_chart_version
  namespace  = kubernetes_namespace.flux_system.metadata[0].name

  create_namespace = false

  wait    = true
  timeout = 300

  #
  # web.enabled schaltet die Flux-Status-Seite (Port 9080) frei - siehe
  # README für die Abwägung, sie ohne Login zu zeigen. Das Chart legt dafür
  # nur eine ClusterIP-Service an (templates/service.yaml kennt keinen
  # service.type) - NodePort kommt deshalb unten als eigene Ressource dazu,
  # statt einen nicht existierenden Values-Schlüssel zu erfinden.
  #
  values = [yamlencode({
    web = {
      enabled = true
    }
  })]
}

#
# Das Chart bindet Port 9080 nur an eine ClusterIP-Service
# (Name kommt aus "flux-operator.fullname" - hier gleich dem Release-Namen
# "flux-operator", weil der Release-Name den Chart-Namen schon enthält).
# Für NodePort-Zugriff eine zweite Service mit denselben Selector-Labels,
# statt das Chart zu etwas zu zwingen, das es nicht vorsieht.
#
resource "kubernetes_service" "flux_web_nodeport" {
  count = var.service_type == "NodePort" ? 1 : 0

  metadata {
    name      = "flux-operator-nodeport"
    namespace = kubernetes_namespace.flux_system.metadata[0].name
  }

  spec {
    type = "NodePort"

    selector = {
      "app.kubernetes.io/name"     = "flux-operator"
      "app.kubernetes.io/instance" = "flux-operator"
    }

    port {
      port        = 9080
      target_port = "http-web"
      node_port   = var.node_port
    }
  }

  depends_on = [helm_release.flux_operator]
}

# =====================================================================
# FluxInstance - die eigentlichen Controller und der Git-Sync
# =====================================================================

#
# Ein einziges Objekt, das dem Operator sagt: welche Flux-Version, welche
# Controller, welches Repo. Braucht die CRD aus helm_release.flux_operator -
# beim allerersten `terraform apply` kann das scheitern, weil Terraform die
# Struktur des Manifests gegen ein CRD-Schema validiert, das noch nicht im
# Cluster ist. Genau das Muster aus k8s/platform/README.md
# (data.kubernetes_config_map.step_ca_certs): zweiter `terraform apply`
# behebt es, siehe README hier.
#
resource "kubernetes_manifest" "flux_instance" {
  manifest = {
    apiVersion = "fluxcd.controlplane.io/v1"
    kind       = "FluxInstance"

    metadata = {
      name      = "flux"
      namespace = kubernetes_namespace.flux_system.metadata[0].name
    }

    spec = {
      distribution = {
        version  = var.flux_version
        registry = "ghcr.io/fluxcd"
      }

      components = [
        "source-controller",
        "kustomize-controller",
        "helm-controller",
        "notification-controller",
      ]

      cluster = {
        type = "kubernetes"
        size = "small"

        #
        # false, weil hier ein einzelner Autor auf var.git_branch schreibt -
        # dieselbe Vertrauensbasis, die bislang für Portainers Auto-Deploy
        # galt. Mit multitenant: true schränkt sich das kustomize-controller
        # von selbst auf definierte Service-Accounts pro Namespace ein; das
        # kommt, sobald mehr als eine Quelle auf diesen Cluster schreibt.
        #
        multitenant   = false
        networkPolicy = true
      }

      sync = {
        kind = "GitRepository"
        url  = var.git_url
        ref  = "refs/heads/${var.git_branch}"
        path = var.sync_path

        #
        # Verweist auf kubernetes_secret.flux_git_auth oben - leer angelegt,
        # bis jemand die Werte per kubectl einträgt. Siehe outputs.tf
        # (fill_secret) und README.
        #
        pullSecret = var.git_secret_name
      }
    }
  }

  depends_on = [
    helm_release.flux_operator,
    kubernetes_secret.flux_git_auth,
  ]
}
