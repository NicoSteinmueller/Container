#
# Headlamp - ein Cluster-Dashboard für den Node aus vm/talos-simple.
#
# Warum ein eigenes Modul und nicht ein paar Zeilen in vm/talos-simple:
# Dort steht ausdrücklich nur das, was der Cluster zum Hochkommen braucht -
# alles Weitere kommt "später und woanders". Das ist hier nicht Förmlichkeit,
# sondern der praktische Unterschied: Ein kaputtes Dashboard darf kein
# `terraform apply` blockieren, das den Cluster aufbaut, und ein
# `terraform destroy` des Clusters darf nicht daran hängenbleiben, dass ein
# Helm-Release aus einer API entfernt werden will, die es nicht mehr gibt.
#
# Warum Headlamp und nicht das Kubernetes-Dashboard oder Rancher - die
# Abwägung steht ausführlich in values/headlamp.yaml.tftpl.
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
# Ein Pfad, kein Wert aus einer anderen Ressource: Provider dürfen ihre
# Konfiguration nicht aus etwas beziehen, das im selben Lauf erst entsteht.
# Genau deshalb sind Cluster und Dashboard zwei getrennte Läufe.
#
provider "helm" {
  kubernetes {
    config_path = var.kubeconfig_path
  }
}

provider "kubernetes" {
  config_path = var.kubeconfig_path
}

locals {
  # Der ServiceAccount, unter dem der Pod läuft - und zugleich die Identität
  # des Lese-Tokens. Siehe kubernetes_service_account.headlamp.
  service_account       = "headlamp"
  admin_service_account = "headlamp-admin"
}

# =====================================================================
# Namespace
# =====================================================================

#
# PodSecurity "restricted", obwohl der Cluster ab Werk nur "baseline"
# erzwingt (Talos-Voreinstellung der Admission-Config).
#
# Die Werte in values/headlamp.yaml.tftpl erfüllen "restricted" ohnehin -
# das Label sorgt dafür, dass das so bleibt. Ohne es fällt eine spätere
# Änderung, die etwa `readOnlyRootFilesystem` verliert, niemandem auf.
#
resource "kubernetes_namespace" "headlamp" {
  metadata {
    name = var.namespace

    labels = {
      "pod-security.kubernetes.io/enforce"         = "restricted"
      "pod-security.kubernetes.io/enforce-version" = "latest"
      "pod-security.kubernetes.io/warn"            = "restricted"
      "pod-security.kubernetes.io/audit"           = "restricted"
    }
  }
}

# =====================================================================
# Rechte
# =====================================================================

#
# Die Rechte kommen bewusst von hier und nicht aus dem Chart.
#
# Das Headlamp-Chart bindet seinen ServiceAccount ab Werk an cluster-admin
# (clusterRoleBinding.clusterRoleName: cluster-admin). Das ist die
# Voreinstellung, kein Versehen - und genau das, was hier nicht passieren
# soll: ein dauerhaft laufender Pod mit Vollzugriff hinter einer
# Weboberfläche.
#
# Die Aufteilung ist deshalb:
#
#   headlamp        - Identität des Pods und des Lese-Tokens. Darf lesen,
#                     nichts ändern, und kommt an keine Secrets.
#   headlamp-admin  - ein ServiceAccount ohne Pod und ohne Token. Wer ändern
#                     will, erzeugt sich eines für eine Stunde.
#
# Der Unterschied ist der Kern: Ein übernommener Dashboard-Pod ist ein
# Leseleck, kein Cluster-Admin.
#
resource "kubernetes_service_account" "headlamp" {
  metadata {
    name      = local.service_account
    namespace = kubernetes_namespace.headlamp.metadata[0].name
  }

  # Headlamp spricht als dieser ServiceAccount mit der API und braucht das
  # Token im Pod - hier also richtig, anders als beim Admin unten.
  automount_service_account_token = true
}

#
# Erste Hälfte der Leserechte: die eingebaute Rolle `view`.
#
# Sie deckt ab, was in Namespaces liegt - Pods, Deployments, Services,
# ConfigMaps, Events, Logs. Wichtig ist, was sie ausdrücklich nicht enthält:
# Secrets. Das ist der Grund, `view` zu nehmen statt eine eigene Rolle mit
# "alles lesen" - die Ausnahme für Secrets ist dort eingebaut und geht beim
# Zusammenschreiben einer eigenen Liste erfahrungsgemäß verloren.
#
resource "kubernetes_cluster_role_binding" "view" {
  metadata {
    name = "headlamp-view"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "view"
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.headlamp.metadata[0].name
    namespace = kubernetes_namespace.headlamp.metadata[0].name
  }
}

#
# Zweite Hälfte: was `view` nicht kennt.
#
# `view` ist auf Objekte in Namespaces zugeschnitten. Alles Clusterweite
# fehlt darin - Nodes, PersistentVolumes, StorageClasses, CRDs. Ohne diese
# Rolle startet das Dashboard, zeigt aber auf der Übersichtsseite überall
# "Forbidden", und die Node-Ansicht bleibt leer.
#
resource "kubernetes_cluster_role" "cluster_read" {
  metadata {
    name = "headlamp-cluster-read"
  }

  # Clusterweite Kernobjekte.
  rule {
    api_groups = [""]
    resources  = ["nodes", "persistentvolumes"]
    verbs      = ["get", "list", "watch"]
  }

  #
  # Auslastung. In diesem Aufbau liefert noch niemand metrics.k8s.io - die
  # Regel steht trotzdem hier, damit die CPU- und Speicheranzeigen von selbst
  # funktionieren, sobald ein metrics-server dazukommt. Ohne ihn ist sie
  # wirkungslos, nicht falsch.
  #
  rule {
    api_groups = ["metrics.k8s.io"]
    resources  = ["nodes", "pods"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["storage.k8s.io"]
    resources  = ["storageclasses", "volumeattachments", "csidrivers", "csinodes", "csistoragecapacities"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["networking.k8s.io"]
    resources  = ["ingressclasses"]
    verbs      = ["get", "list", "watch"]
  }

  #
  # Die CRD-Objekte selbst, nicht deren Inhalte. Dieser Cluster hat noch
  # keine; kommen welche dazu (Cilium, cert-manager, Traefik), braucht jede
  # Gruppe eine eigene Regel. Eine Wildcard über alle apiGroups wäre kürzer
  # und würde jede künftige CRD einschließen - auch eine, die Zugangsdaten im
  # Klartext in ihrer Spec trägt.
  #
  rule {
    api_groups = ["apiextensions.k8s.io"]
    resources  = ["customresourcedefinitions"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["apiregistration.k8s.io"]
    resources  = ["apiservices"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["scheduling.k8s.io"]
    resources  = ["priorityclasses"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["node.k8s.io"]
    resources  = ["runtimeclasses"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["admissionregistration.k8s.io"]
    resources  = ["mutatingwebhookconfigurations", "validatingwebhookconfigurations"]
    verbs      = ["get", "list", "watch"]
  }

  #
  # RBAC lesen dürfen. Die eine Regel hier, die eine Abwägung ist: Wer Rollen
  # und Bindungen liest, sieht, wo im Cluster die weitreichenden Rechte
  # liegen. Sie steht trotzdem drin, weil ein Dashboard, das die Rechtevergabe
  # nicht zeigt, genau bei der Frage aussteigt, für die man es aufmacht.
  # Lesen allein erlaubt keine Ausweitung - ohne `escalate` oder `bind` kann
  # dieser ServiceAccount keine Rolle vergeben, auch keine, die er sieht.
  #
  rule {
    api_groups = ["rbac.authorization.k8s.io"]
    resources  = ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]
    verbs      = ["get", "list", "watch"]
  }

  #
  # Headlamp fragt beim Anmelden ab, was es überhaupt anzeigen darf, statt
  # jede Ansicht in einen Fehler laufen zu lassen. `system:basic-user` bringt
  # das im Normalfall schon mit; ausdrücklich hier, damit die Oberfläche nicht
  # davon abhängt.
  #
  rule {
    api_groups = ["authorization.k8s.io"]
    resources  = ["selfsubjectaccessreviews", "selfsubjectrulesreviews"]
    verbs      = ["create"]
  }
}

resource "kubernetes_cluster_role_binding" "cluster_read" {
  metadata {
    name = "headlamp-cluster-read"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.cluster_read.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.headlamp.metadata[0].name
    namespace = kubernetes_namespace.headlamp.metadata[0].name
  }
}

#
# Der Weg zum Schreibzugriff, wenn er gebraucht wird.
#
# Dieser ServiceAccount wird von keinem Pod verwendet und hat kein Secret mit
# einem Token. Er ist damit im Ruhezustand nicht benutzbar: Ein Token entsteht
# erst durch einen ausdrücklichen Aufruf der TokenRequest-API, und der setzt
# ein kubeconfig mit Adminrechten voraus - wer das hat, ist ohnehin schon
# Cluster-Admin.
#
#   kubectl -n <namespace> create token headlamp-admin --duration=1h
#
resource "kubernetes_service_account" "admin" {
  count = var.admin_service_account ? 1 : 0

  metadata {
    name      = local.admin_service_account
    namespace = kubernetes_namespace.headlamp.metadata[0].name
  }

  automount_service_account_token = false
}

resource "kubernetes_cluster_role_binding" "admin" {
  count = var.admin_service_account ? 1 : 0

  metadata {
    name = "headlamp-admin"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.admin[0].metadata[0].name
    namespace = kubernetes_namespace.headlamp.metadata[0].name
  }
}

# =====================================================================
# Metriken
# =====================================================================

#
# metrics-server - Quelle für `kubectl top` und für die Auslastungsanzeigen
# (CPU, Speicher) im Dashboard. Ohne ihn bleiben die entsprechenden Felder in
# Headlamp leer, obwohl die RBAC-Regel für metrics.k8s.io schon bereitsteht
# (kubernetes_cluster_role.cluster_read oben).
#
# Läuft in kube-system, nicht in einem eigenen Namespace: Er meldet sich als
# APIService v1beta1.metrics.k8s.io an, der kube-apiserver reicht Anfragen an
# ihn weiter. Ein eigener Namespace mit Default-Deny-Policies müsste genau
# diesen Weg wieder öffnen - und hier gibt es ohnehin noch keine
# NetworkPolicies, die das beträfe.
#
resource "helm_release" "metrics_server" {
  count = var.metrics_server_enabled ? 1 : 0

  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = var.metrics_server_chart_version
  namespace  = "kube-system"

  wait    = true
  timeout = 300

  values = [file("${path.module}/values/metrics-server.yaml")]
}

# =====================================================================
# Dashboard
# =====================================================================

resource "helm_release" "headlamp" {
  name       = "headlamp"
  repository = "https://kubernetes-sigs.github.io/headlamp/"
  chart      = "headlamp"
  version    = var.headlamp_chart_version
  namespace  = kubernetes_namespace.headlamp.metadata[0].name

  # Der Namespace kommt von oben, mit PodSecurity-Labels. Legte das Chart ihn
  # an, wäre er unbeschriftet und damit auf der Cluster-Voreinstellung.
  create_namespace = false

  wait    = true
  timeout = 300

  values = [templatefile("${path.module}/values/headlamp.yaml.tftpl", {
    service_account = local.service_account
    cluster_name    = var.cluster_name
    service_type    = var.service_type
    node_port       = var.node_port
    session_ttl     = var.session_ttl
    namespace       = var.namespace
  })]

  #
  # Ohne den ServiceAccount käme der Pod nicht über ContainerCreating hinaus -
  # das Chart legt ihn hier nicht selbst an (serviceAccount.create: false).
  #
  depends_on = [
    kubernetes_service_account.headlamp,
    kubernetes_cluster_role_binding.view,
    kubernetes_cluster_role_binding.cluster_read,
  ]
}
