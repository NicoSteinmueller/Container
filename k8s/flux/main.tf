#
# Flux (GitOps) für den Cluster aus vm/talos-simple - Push auf var.git_branch
# rollt aus.
#
terraform {
  #
  # State in der Gitea-Package-Registry
  #
  backend "http" {
    address        = "https://git.local.nico-steinmueller.de/api/packages/nico/terraform/state/k8s-flux"
    lock_address   = "https://git.local.nico-steinmueller.de/api/packages/nico/terraform/state/k8s-flux/lock"
    unlock_address = "https://git.local.nico-steinmueller.de/api/packages/nico/terraform/state/k8s-flux/lock"
    lock_method    = "POST"
    unlock_method  = "DELETE"
  }

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
# Beide Provider über die kubeconfig aus vm/talos-simple - ein Pfad, kein Wert
# aus einer anderen Ressource.
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
# Bewusst ohne pod-security enforce: restricted, anders als bei Headlamp -
# die Controller müssen anwenden dürfen, was im Repo steht.
#
resource "kubernetes_namespace" "flux_system" {
  metadata {
    name = var.namespace
  }

  #
  # Die FluxInstance verwaltet flux-system mit und setzt eigene
  # Labels/Annotations - ohne ignore_changes entfernt sie jeder apply wieder.
  #
  lifecycle {
    ignore_changes = [metadata[0].labels, metadata[0].annotations]
  }
}

#
# Leer angelegt: Der PAT als Terraform-Variable stünde im Klartext im State.
# Das Objekt existiert nur, damit die FluxInstance einen gültigen
# pullSecret-Namen hat; befüllt wird per `kubectl patch secret` (outputs.tf,
# fill_secret). ignore_changes hält diesen Wert - sonst setzt ihn der nächste
# apply auf die leeren Platzhalter zurück.
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
# Nur der Operator und seine CRDs (u.a. FluxInstance). Die Flux-Controller
# selbst richtet er erst anhand von helm_release.flux_instance unten ein.
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
  # Schaltet die Flux-Status-Seite (Port 9080) frei - ohne Login.
  #
  values = [yamlencode({
    web = {
      enabled = true
    }
  })]
}

#
# Das Chart kennt keinen service.type und legt nur eine ClusterIP-Service an -
# für NodePort deshalb eine zweite Service mit denselben Selector-Labels.
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
# Ein Objekt, das dem Operator sagt: welche Flux-Version, welche Controller,
# welches Repo.
#
resource "helm_release" "flux_instance" {
  name       = "flux"
  repository = "oci://ghcr.io/controlplaneio-fluxcd/charts"
  chart      = "flux-instance"
  version    = var.flux_instance_chart_version
  namespace  = kubernetes_namespace.flux_system.metadata[0].name

  create_namespace = false

  #
  # wait gilt nur dem Anlegen, nicht einem gesunden Sync: healthcheck.enabled
  # bleibt aus (Chart-Default), sonst liefe der apply ohne den erst danach
  # eingetragenen PAT zwangsläufig in seinen Timeout.
  #
  wait    = true
  timeout = 300

  values = [yamlencode({
    instance = {
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

        # false: ein einzelner Autor schreibt auf var.git_branch (README).
        multitenant   = false
        networkPolicy = true
      }

      sync = {
        kind = "GitRepository"
        url  = var.git_url
        ref  = "refs/heads/${var.git_branch}"
        path = var.sync_path

        # kubernetes_secret.flux_git_auth oben - leer bis zum kubectl patch.
        pullSecret = var.git_secret_name
      }
    }
  })]

  depends_on = [
    helm_release.flux_operator,
    kubernetes_secret.flux_git_auth,
  ]
}
