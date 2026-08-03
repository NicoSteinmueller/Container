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
  description = "Namespace des Dashboards. Wird von diesem Modul angelegt, mit PodSecurity \"restricted\"."
  type        = string
  default     = "headlamp"
}

variable "cluster_name" {
  description = <<-EOT
    Name, unter dem der Cluster in der Oberfläche erscheint. Reine Anzeige -
    Headlamp spricht in diesem Aufbau immer mit dem Cluster, in dem es läuft.
  EOT
  type        = string
  default     = "talos-cp1"
}

variable "headlamp_chart_version" {
  description = "Chart-Version von Headlamp (Cluster-Dashboard)."
  type        = string
  default     = "0.44.0"
}

#
# Der Weg hinein
#
# Dieser Cluster hat weder Ingress-Controller noch cert-manager - es gibt also
# keine Stelle, die TLS terminieren könnte. Headlamp selbst spricht HTTP.
# Damit stehen genau zwei Wege zur Wahl, und der Unterschied ist nicht die
# Bequemlichkeit, sondern ob das Token im Klartext über das Heimnetz geht.
#
variable "service_type" {
  description = <<-EOT
    Wie das Dashboard erreichbar ist:

      ClusterIP  - gar nicht von außen. Der Zugang läuft über

                     kubectl -n <namespace> port-forward svc/headlamp 8080:80

                   und damit TLS-geschützt durch den API-Server. Voreinstellung,
                   weil die Anmeldung ein Bearer-Token ist: Wer es unterwegs
                   mitliest, hat bis zum Ablauf dieselben Rechte wie der
                   Angemeldete - beim Admin-Token also Vollzugriff.

      NodePort   - erreichbar unter http://<lan_ip>:<node_port> von jedem Gerät
                   im Heimnetz, ohne kubectl. Der Preis ist genau das eben
                   Genannte: unverschlüsseltes HTTP im LAN.

    Der dritte Weg - eigener Name, TLS, interne CA - kommt mit dem
    Plattform-Stack in k8s/platform und ersetzt beides hier.
  EOT
  type        = string
  default     = "ClusterIP"

  validation {
    condition     = contains(["ClusterIP", "NodePort"], var.service_type)
    error_message = "service_type muss ClusterIP oder NodePort sein."
  }
}

variable "node_port" {
  description = <<-EOT
    Port auf dem Node, nur bei service_type = "NodePort". Muss im
    NodePort-Bereich liegen (30000-32767).

    Die 30080 ist als Erinnerung gewählt: Hier läuft HTTP, nicht HTTPS.
  EOT
  type        = number
  default     = 30080

  validation {
    condition     = var.node_port >= 30000 && var.node_port <= 32767
    error_message = "node_port muss zwischen 30000 und 32767 liegen."
  }
}

#
# Anmeldung
#
variable "admin_service_account" {
  description = <<-EOT
    Den ServiceAccount headlamp-admin mit cluster-admin anlegen.

    Er hat keinen Pod und kein Token: Wer im Dashboard ändern will, erzeugt
    sich eines für eine Stunde und fügt es dort ein.

      kubectl -n <namespace> create token headlamp-admin --duration=1h

    Auf false, wenn im Dashboard ausschließlich gelesen werden soll - dann
    wird im Cluster nur per kubectl geändert.
  EOT
  type        = bool
  default     = true
}

variable "session_ttl" {
  description = <<-EOT
    Sitzungsdauer der Oberfläche in Sekunden. Kürzer als die Voreinstellung
    des Charts (24 h), aber lang genug, um nicht bei jedem Blick ins Cluster
    ein neues Token einzufügen.

    Begrenzt nur die Sitzung im Browser. Wie lange das Token selbst gilt,
    entscheidet --duration beim Erzeugen.
  EOT
  type        = number
  default     = 28800
}
