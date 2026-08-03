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
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "helm" {
  kubernetes {
    config_path = var.kubeconfig_path
  }
}

provider "kubernetes" {
  config_path = var.kubeconfig_path
}

locals {
  public_namespaces = [for ns in var.app_namespaces : ns.name if ns.zone == "public"]

  #
  # Was ingress-internal beobachtet: die internen Anwendungen plus das
  # Dashboard.
  #
  # Das Dashboard steht bewusst nicht in var.app_namespaces, sondern wird hier
  # angehängt - siehe local.ns_headlamp. Vergisst man das Anhängen, entsteht
  # ein Fehlerbild, das nach einem Problem am Dashboard aussieht und keines
  # ist: Der Pod läuft, der Ingress existiert, und der Aufruf im Browser
  # läuft trotzdem in eine Zeitüberschreitung - weil der Controller mit
  # namespaced RBAC nur die Namespaces liest, die hier aufgezählt sind.
  #
  internal_namespaces = concat(
    [for ns in var.app_namespaces : ns.name if ns.zone == "internal"],
    var.dashboard.enabled ? [local.ns_headlamp] : [],
  )

  #
  # Infrastruktur-Namespaces. Sie stehen hier und nicht in einer Variablen,
  # weil an ihnen NetworkPolicies, PodSecurity-Stufen und die RBAC-Grenzen der
  # beiden Ingress-Controller hängen - das ist Struktur, keine Konfiguration.
  #
  ns_traefik_public   = "traefik-public"
  ns_traefik_internal = "traefik-internal"
  ns_cert_manager     = "cert-manager"
  ns_step_ca          = "step-ca"
  ns_crowdsec         = "crowdsec"
  ns_kyverno          = "kyverno"
  ns_storage          = "local-path-storage"

  #
  # Das Dashboard steht hier bei der Infrastruktur und nicht in
  # var.app_namespaces, obwohl es aus Sicht von ingress-internal eine
  # gewöhnliche Anwendung ist.
  #
  # Der Grund ist derselbe wie oben: An diesem Namespace hängt ein
  # ClusterRole-Binding, das clusterweit lesen darf. Stünde er in der
  # Variablen, könnte eine Zeile in terraform.tfvars ihn auf zone = "public"
  # umstellen - und damit ein Dashboard mit Cluster-Lesezugriff hinter den
  # Ingress stellen, der aus dem Internet erreichbar ist. Als
  # Infrastruktur-Namespace ist "internal" keine Einstellung, sondern eine
  # Eigenschaft.
  #
  ns_headlamp = "headlamp"

  dashboard_host = var.dashboard.host != "" ? var.dashboard.host : "dashboard.${var.domain}"

  #
  # Der Aussteller für die internen Namen. Welcher es ist, entscheidet
  # var.internal_acme - siehe charts/homelab-policies/templates/cluster-issuers.yaml.
  #
  internal_cluster_issuer = var.internal_acme.enabled ? "internal-acme" : "internal-ca"

  step_ca_service = "step-ca.${local.ns_step_ca}.svc.cluster.local"
  step_ca_url     = "https://${local.step_ca_service}:9000"
  lapi_service    = "crowdsec-service.${local.ns_crowdsec}.svc.cluster.local"

  # Serverzertifikat von ingress-public. Gefüllt aus dem Namespace step-ca,
  # gelesen im Namespace traefik-public - siehe helm_release.pki.
  ingress_public_tls_secret = "ingress-public-tls"

  #
  # Inhaltsprüfsumme der drei lokalen Charts.
  #
  # Der Helm-Provider bemerkt Änderungen an lokalen Chart-Dateien nicht: Er
  # vergleicht `values`, `version` und ein paar Metafelder, aber nicht das
  # Chart-Verzeichnis. Wer ein Template hier ändert und `terraform apply`
  # ausführt, bekommt deshalb "No changes" - und wundert sich, warum die
  # Korrektur im Cluster nicht ankommt. Das ist besonders tückisch, weil der
  # Lauf erfolgreich aussieht.
  #
  # Die Prüfsumme geht als Wert mit in die Release. Helm ignoriert unbenutzte
  # Werte, aber Terraform sieht die Änderung und führt ein Upgrade aus. Beim
  # Ändern eines Templates also nichts weiter zu tun - es greift von selbst.
  #
  chart_hashes = {
    for name in ["homelab-base", "homelab-pki", "homelab-policies"] :
    name => sha256(join("", [
      for f in sort(tolist(fileset("${path.module}/charts/${name}", "**"))) :
      filesha256("${path.module}/charts/${name}/${f}")
    ]))
  }
}

#
# Passwörter der internen CA.
#
# Sie liegen im Terraform-State (der ist per .gitignore ausgeschlossen und
# gleichbedeutend mit Cluster-Admin) und sonst nur in zwei Secrets im
# Namespace step-ca, die der Chart dort anlegt. Aus diesem Namespace kommen
# sie nicht heraus: Weder die Edge-VM noch ingress-public bekommen ein
# Provisioner-Passwort.
#
# Die Edge holt ihr Client-Zertifikat mit einem Token, das nach Minuten
# abläuft (vm/edge: edge-mtls-bootstrap). Das Serverzertifikat von
# ingress-public stellt ein Aussteller im Namespace der CA aus und legt es
# als Secret in den Namespace des Ingress (charts/homelab-pki).
#
resource "random_password" "step_ca" {
  length  = 32
  special = false
}

resource "random_password" "step_provisioner" {
  length  = 32
  special = false
}

# =====================================================================
# Schicht 1: Namespaces, Netzgrenzen, Storage
# =====================================================================

#
# Lokales Chart statt einzelner kubernetes_manifest-Ressourcen: Die Objekte
# hier hängen an keiner CRD, aber sie sind viele und gehören zusammen. Über
# ein Chart bleiben sie als Einheit sichtbar - und `helm diff` zeigt vor dem
# Anwenden, was sich ändert.
#
resource "helm_release" "base" {
  name      = "homelab-base"
  chart     = "${path.module}/charts/homelab-base"
  namespace = "kube-system"

  wait    = true
  timeout = 300

  values = [yamlencode({
    # Erzwingt ein Upgrade, wenn sich eine Datei im Chart aendert - siehe
    # local.chart_hashes.
    chartHash = local.chart_hashes["homelab-base"]

    namespaces = {
      traefikPublic   = local.ns_traefik_public
      traefikInternal = local.ns_traefik_internal
      certManager     = local.ns_cert_manager
      stepCa          = local.ns_step_ca
      crowdsec        = local.ns_crowdsec
      kyverno         = local.ns_kyverno
      storage         = local.ns_storage
      headlamp        = local.ns_headlamp
    }

    apps = var.app_namespaces

    # Namespace, PodSecurity-Stufe und Netzgrenzen des Dashboards. Die
    # Release selbst steht weiter unten, die Rechte in homelab-policies.
    headlamp = {
      enabled = var.dashboard.enabled
    }

    network = {
      lanCidr   = var.lan_cidr
      dmzCidr   = "${var.edge_dmz_ip}/32"
      nodeLanIp = var.node_lan_ip
      nodeDmzIp = var.node_dmz_ip
    }

    localPath = {
      enabled = true
      path    = var.storage_class_path
    }
  })]
}

# =====================================================================
# Schicht 2: PKI
# =====================================================================

#
# cert-manager - zuständig für die internen Namen (ingress-internal) und
# ausdrücklich nicht für die Strecke Edge -> Cluster. Das ist die Aufteilung
# aus dem Konzept: zwei ACME-Clients, die nichts voneinander wissen.
#
resource "helm_release" "cert_manager" {
  name       = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = var.cert_manager_version
  namespace  = local.ns_cert_manager

  wait    = true
  timeout = 600

  values = [file("${path.module}/values/cert-manager.yaml")]

  depends_on = [helm_release.base]
}

#
# step-ca: die interne CA.
#
# Warum step-ca und nicht cert-manager für diese Strecke: Die Edge-VM steht
# außerhalb des Clusters und muss ihr Client-Zertifikat alle 24 h selbst
# erneuern. Dafür braucht es eine Online-CA mit API - cert-manager hat keine,
# die von außen ansprechbar wäre, ohne der Edge Cluster-Zugangsdaten zu geben.
# Genau das soll nicht sein (Konzept: "kein kubeconfig, kein ServiceAccount-
# Token, keine Talos-Credentials" auf der Edge).
#
# Wurzel und Intermediate entstehen beim ersten Start im Cluster, nicht in
# Terraform. Der private Schlüssel der CA verlässt den Namespace step-ca
# damit nie - auch nicht in den State.
#
resource "helm_release" "step_ca" {
  name       = "step-ca"
  repository = "https://smallstep.github.io/helm-charts"
  chart      = "step-certificates"
  version    = var.step_ca_chart_version
  namespace  = local.ns_step_ca

  wait    = true
  timeout = 900

  values = [templatefile("${path.module}/values/step-ca.yaml.tftpl", {
    node_dmz_ip          = var.node_dmz_ip
    service_fqdn         = local.step_ca_service
    ca_password          = random_password.step_ca.result
    provisioner_password = random_password.step_provisioner.result
    cert_lifetime        = var.cert_lifetime
  })]

  depends_on = [helm_release.base]
}

#
# Das Wurzelzertifikat der internen CA. Öffentlich, aber erst nach dem
# Bootstrap-Job bekannt - deshalb ein Data Source mit depends_on statt eines
# Werts aus Terraform.
#
# Falls hier beim allerersten Anwenden nichts steht: `terraform apply` ein
# zweites Mal laufen lassen. Dann ist der Job durch.
#
data "kubernetes_config_map" "step_ca_certs" {
  metadata {
    name      = "step-ca-certs"
    namespace = local.ns_step_ca
  }

  depends_on = [helm_release.step_ca]
}

#
# Dieselbe Wurzel im Namespace von ingress-public. Zwei Verwendungen:
#
#   1. clientAuth - ingress-public akzeptiert nur Verbindungen mit einem
#      Client-Zertifikat aus dieser CA. Das ist Entscheidung E5, und ohne
#      diese Datei wäre das Client-Zertifikat der Edge nur Dekoration.
#   2. Als Vertrauensanker, wenn sich ingress-public sein eigenes
#      Serverzertifikat bei step-ca holt.
#
# Bewusst kopiert statt den Namespace step-ca für Traefik lesbar zu machen:
# Traefik bekommt in jedem beobachteten Namespace Leserecht auf Secrets - im
# Namespace der CA läge dort der Wurzelschlüssel.
#
resource "kubernetes_config_map" "internal_ca" {
  metadata {
    name      = "internal-ca"
    namespace = local.ns_traefik_public
  }

  data = {
    "root_ca.crt" = data.kubernetes_config_map.step_ca_certs.data["root_ca.crt"]
  }

  depends_on = [helm_release.base]
}

#
# Das Serverzertifikat von ingress-public.
#
# Es entsteht im Namespace step-ca und kommt als fertiges TLS-Secret hier an.
# Der frühere Weg - ein Init-Container im Ingress-Pod, der es sich mit dem
# Provisioner-Passwort selbst holt - war bequemer und an einer Stelle falsch:
# Traefik bekommt mit namespaced RBAC Leserecht auf Secrets in seinem eigenen
# Namespace. Ein Provisioner-Passwort dort wäre nach einer Übernahme des
# Ingress ein Schlüssel zur internen CA gewesen, mit dem sich Zertifikate auf
# beliebige Namen ausstellen lassen - auch auf den der Edge-VM.
#
# Ausführlich in charts/homelab-pki/templates/ingress-cert.yaml.
#
# Muss vor traefik_public laufen: Ohne das Secret käme dessen Pod nicht über
# ContainerCreating hinaus. Der Hook-Job im Chart stellt sicher, dass Helm auf
# die erste Ausstellung wartet.
#
resource "helm_release" "pki" {
  name      = "homelab-pki"
  chart     = "${path.module}/charts/homelab-pki"
  namespace = local.ns_step_ca

  wait    = true
  timeout = 600

  values = [yamlencode({
    # Erzwingt ein Upgrade, wenn sich eine Datei im Chart aendert - siehe
    # local.chart_hashes.
    chartHash = local.chart_hashes["homelab-pki"]

    namespaces = {
      stepCa        = local.ns_step_ca
      traefikPublic = local.ns_traefik_public
    }

    stepCa = {
      url         = local.step_ca_url
      provisioner = "homelab"
    }

    ingressPublic = {
      serverName = var.ingress_public_server_name
      nodeDmzIp  = var.node_dmz_ip
      tlsSecret  = local.ingress_public_tls_secret
    }

    certLifetime = var.cert_lifetime

    images = {
      step    = var.step_cli_image
      kubectl = var.kubectl_image
    }
  })]

  depends_on = [
    helm_release.step_ca,
    kubernetes_config_map.internal_ca,
  ]
}

# =====================================================================
# Schicht 3: Policy
# =====================================================================

#
# Kyverno. Es steht vor den Ingress-Controllern in der Reihenfolge, weil die
# Regel auf ingressClassName sonst erst greift, wenn schon etwas ausgerollt
# ist, das sie hätte prüfen sollen.
#
resource "helm_release" "kyverno" {
  name       = "kyverno"
  repository = "https://kyverno.github.io/kyverno"
  chart      = "kyverno"
  version    = var.kyverno_chart_version
  namespace  = local.ns_kyverno

  wait    = true
  timeout = 600

  values = [file("${path.module}/values/kyverno.yaml")]

  depends_on = [helm_release.base]
}

# =====================================================================
# Schicht 4: Ingress
# =====================================================================

#
# ingress-public - der einzige Weg von der DMZ nach innen.
#
# Drei Ports, alle an ${var.node_dmz_ip} gebunden, alle nur von der Edge-VM
# erreichbar (Talos-Ingress-Firewall in vm/talos):
#
#   443  Nutzverkehr, mTLS gegen die interne CA
#   8443 CrowdSec-LAPI, über dieselbe mTLS-Strecke
#   9000 step-ca, TCP-Passthrough (die Edge prüft dort den Fingerprint)
#
resource "helm_release" "traefik_public" {
  name       = "traefik-public"
  repository = "https://traefik.github.io/charts"
  chart      = "traefik"
  version    = var.traefik_chart_version
  namespace  = local.ns_traefik_public

  wait    = true
  timeout = 600

  values = [templatefile("${path.module}/values/traefik-public.yaml.tftpl", {
    namespace           = local.ns_traefik_public
    node_dmz_ip         = var.node_dmz_ip
    edge_dmz_ip         = var.edge_dmz_ip
    ingress_public_port = var.ingress_public_port
    lapi_port           = var.crowdsec_lapi_port
    step_ca_port        = var.step_ca_port
    server_name         = var.ingress_public_server_name
    step_cli_image      = var.step_cli_image
    tls_secret          = local.ingress_public_tls_secret
    watch_namespaces    = local.public_namespaces
  })]

  depends_on = [
    kubernetes_config_map.internal_ca,
    helm_release.pki,
    helm_release.kyverno,
  ]
}

#
# ingress-internal - Paperless und die Verwaltungsoberflächen, nur aus dem
# LAN. Getrennter Controller statt getrennter Konfiguration: Das ist
# Entscheidung E6, und die Netzgrenze ist hier die Bindung an ${var.node_lan_ip}.
#
resource "helm_release" "traefik_internal" {
  name       = "traefik-internal"
  repository = "https://traefik.github.io/charts"
  chart      = "traefik"
  version    = var.traefik_chart_version
  namespace  = local.ns_traefik_internal

  wait    = true
  timeout = 600

  values = [templatefile("${path.module}/values/traefik-internal.yaml.tftpl", {
    node_lan_ip      = var.node_lan_ip
    lan_cidr         = var.lan_cidr
    watch_namespaces = local.internal_namespaces
  })]

  depends_on = [helm_release.kyverno]
}

# =====================================================================
# Schicht 5: Abwehr
# =====================================================================

#
# CrowdSec: LAPI und Agent im Cluster.
#
# Die LAPI gehört hierher und nicht auf die Edge-VM - die Edge ist die
# Komponente mit Internetkontakt und damit die, die am ehesten kompromittiert
# wird. Läge die Entscheidungsdatenbank dort, könnte ein Angreifer die
# Sperrliste löschen, die ihn blockiert (Entscheidung E7).
#
# Der Agent hier liest Anwendungslogs, nicht Proxy-Logs: Ein fehlgeschlagener
# Nextcloud-Login über das Webformular liefert HTTP 200 und ist aus
# Proxy-Sicht nicht von normalem Surfen zu unterscheiden.
#
resource "helm_release" "crowdsec" {
  name       = "crowdsec"
  repository = "https://crowdsecurity.github.io/helm-charts"
  chart      = "crowdsec"
  version    = var.crowdsec_chart_version
  namespace  = local.ns_crowdsec

  wait    = true
  timeout = 600

  values = [templatefile("${path.module}/values/crowdsec.yaml.tftpl", {
    collections = var.crowdsec_collections

    # Verwaltungsadressen plus das Heimnetz, doppelte Einträge entfernt: Die
    # Liste wird zu einem expr-Ausdruck verkettet, und derselbe Bereich
    # zweimal darin sieht nach einem Fehler aus.
    whitelist_sources = distinct(concat(var.admin_sources, [var.lan_cidr]))

    edge_machine_id = var.crowdsec_edge_machine_id
    app_namespaces  = var.app_namespaces
  })]

  depends_on = [helm_release.base]
}

# =====================================================================
# Schicht 6: Regeln und Verdrahtung (braucht die CRDs von oben)
# =====================================================================

#
# Alles, was auf eine CRD trifft: Kyverno-Policies, die beiden Router von
# ingress-public zu LAPI und step-ca, die ClusterIssuer von cert-manager.
#
# Bewusst zuletzt: Ein Chart, das ClusterPolicy, IngressRoute und
# ClusterIssuer mischt, lässt sich nur anwenden, wenn alle drei CRD-Sätze
# schon im Cluster sind.
#
resource "helm_release" "policies" {
  name      = "homelab-policies"
  chart     = "${path.module}/charts/homelab-policies"
  namespace = "kube-system"

  wait    = true
  timeout = 300

  values = [yamlencode({
    # Erzwingt ein Upgrade, wenn sich eine Datei im Chart aendert - siehe
    # local.chart_hashes.
    chartHash = local.chart_hashes["homelab-policies"]

    namespaces = {
      traefikPublic   = local.ns_traefik_public
      traefikInternal = local.ns_traefik_internal
      stepCa          = local.ns_step_ca
      crowdsec        = local.ns_crowdsec
      certManager     = local.ns_cert_manager
      headlamp        = local.ns_headlamp
    }

    publicNamespaces = local.public_namespaces

    # ServiceAccount und Leserechte des Dashboards. Sie stehen hier und nicht
    # in den Werten der Headlamp-Release, weil deren Chart ab Werk an
    # cluster-admin bindet - siehe charts/homelab-policies/templates/dashboard-rbac.yaml.
    headlamp = {
      enabled             = var.dashboard.enabled
      adminServiceAccount = var.dashboard.admin_service_account
    }

    stepCa = {
      serviceFqdn = local.step_ca_service
      port        = 9000
    }

    lapi = {
      serviceFqdn = local.lapi_service
      port        = 8080
    }

    certLifetime = var.cert_lifetime
    domain       = var.domain

    internalAcme = var.internal_acme
  })]

  depends_on = [
    helm_release.kyverno,
    helm_release.traefik_public,
    helm_release.cert_manager,
    helm_release.crowdsec,
  ]
}

# =====================================================================
# Schicht 7: Einblick - Metriken und Dashboard
# =====================================================================

#
# kubelet-csr-approver.
#
# ACHTUNG, Reihenfolge über Modulgrenzen hinweg: Dieser Dienst und
# serverTLSBootstrap in vm/talos/patches/hardening.yaml gehören zusammen und
# müssen in dieser Reihenfolge kommen - erst hier anwenden, dann die
# Talos-Config.
#
# Mit serverTLSBootstrap fordert das Kubelet sein Serverzertifikat über einen
# CSR an, statt sich eines selbst zu unterschreiben. Genehmigt den Antrag
# niemand, bleibt er auf "Pending" - und dann funktionieren `kubectl logs`,
# `kubectl exec` und jeder Metrikabruf nicht mehr. Genau davor warnt der
# Kommentar in hardening.yaml; dieser Dienst ist die Bedingung, unter der die
# Zeile dort vertretbar ist.
#
# Ohne count: Der Genehmiger hängt an der Talos-Config, nicht am Dashboard.
# Wer ihn abschaltet, während serverTLSBootstrap aktiv ist, legt beim
# nächsten Zertifikatswechsel den Node lahm.
#
resource "helm_release" "csr_approver" {
  name       = "kubelet-csr-approver"
  repository = "https://postfinance.github.io/kubelet-csr-approver"
  chart      = "kubelet-csr-approver"
  version    = var.csr_approver_chart_version
  namespace  = "kube-system"

  wait    = true
  timeout = 300

  values = [templatefile("${path.module}/values/kubelet-csr-approver.yaml.tftpl", {
    node_name              = var.node_name
    node_lan_ip            = var.node_lan_ip
    max_expiration_seconds = var.kubelet_cert_max_expiration_seconds
  })]

  depends_on = [helm_release.base]
}

#
# metrics-server. Quelle für `kubectl top` und für die Auslastungsanzeigen im
# Dashboard.
#
# depends_on auf den Genehmiger ist keine Formalität: Ohne ihn hat das
# Kubelet kein prüfbares Serverzertifikat, und metrics-server bleibt mit
# "x509: certificate signed by unknown authority" stehen. Der verbreitete
# Ausweg --kubelet-insecure-tls steht bewusst nicht in den Werten - siehe
# values/metrics-server.yaml.
#
resource "helm_release" "metrics_server" {
  count = var.metrics_server_enabled ? 1 : 0

  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = var.metrics_server_chart_version
  namespace  = "kube-system"

  wait    = true
  timeout = 600

  values = [file("${path.module}/values/metrics-server.yaml")]

  depends_on = [helm_release.csr_approver]
}

#
# Headlamp - das Dashboard, erreichbar nur über ingress-internal.
#
# Die Rechte kommen nicht von diesem Chart: Es bindet seinen ServiceAccount
# ab Werk an cluster-admin. Stattdessen legt homelab-policies zwei
# ServiceAccounts an - einen zum Lesen, unter dem der Pod läuft, und einen
# mit cluster-admin ohne Token für kurzlebige Admin-Sitzungen. Ausführlich in
# charts/homelab-policies/templates/dashboard-rbac.yaml.
#
# Deshalb depends_on auf policies: Ohne den ServiceAccount käme der Pod nicht
# über ContainerCreating hinaus.
#
resource "helm_release" "headlamp" {
  count = var.dashboard.enabled ? 1 : 0

  name       = "headlamp"
  repository = "https://kubernetes-sigs.github.io/headlamp/"
  chart      = "headlamp"
  version    = var.headlamp_chart_version
  namespace  = local.ns_headlamp

  wait    = true
  timeout = 600

  values = [templatefile("${path.module}/values/headlamp.yaml.tftpl", {
    namespace      = local.ns_headlamp
    cluster_name   = var.node_name
    host           = local.dashboard_host
    node_lan_ip    = var.node_lan_ip
    cluster_issuer = local.internal_cluster_issuer
  })]

  depends_on = [
    helm_release.policies,
    helm_release.traefik_internal,
  ]
}
