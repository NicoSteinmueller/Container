#
# Zugang zum Cluster
#
variable "kubeconfig_path" {
  description = <<-EOT
    kubeconfig des Talos-Clusters. Wird von vm/talos geschrieben
    (`terraform output kubeconfig_path`).

    Bewusst über eine Datei statt über einen Remote-State: Die Reihenfolge
    zwischen den beiden Modulen bleibt damit sichtbar - erst der Node, dann
    die Ausstattung.
  EOT
  type        = string
  default     = "../../vm/talos/kubeconfig"
}

#
# Adressen - müssen zu vm/talos und vm/edge passen
#
variable "node_dmz_ip" {
  description = "Adresse des Nodes im DMZ-Segment. Hier hängen ingress-public, CrowdSec-LAPI und step-ca (hostPort mit hostIP)."
  type        = string
  default     = "10.10.20.3"
}

variable "edge_dmz_ip" {
  description = <<-EOT
    Adresse der Edge-VM. Die einzige Quelle, von der ingress-public Verkehr
    annimmt - und die einzige IP, deren X-Forwarded-For geglaubt wird.

    Der zweite Teil ist der Punkt, an dem das Konzept ausdrücklich warnt:
    Steht die Edge nicht in trustedIPs, sieht CrowdSec bei jedem Angriff nur
    die Edge-VM und sperrt am Ende den gesamten Zugang.
  EOT
  type        = string
  default     = "10.10.20.2"
}

variable "node_lan_ip" {
  description = "Adresse des Nodes im Heimnetz. Hier hängt ingress-internal."
  type        = string
  default     = "192.168.178.21"
}

variable "lan_cidr" {
  description = "Heimnetz. Quelle für ingress-internal und Whitelist in CrowdSec."
  type        = string
  default     = "192.168.178.0/24"
}

variable "admin_sources" {
  description = <<-EOT
    Verwaltungsadressen. Landen in der CrowdSec-Whitelist, und zwar so, dass
    eingehende Alarme sie nicht überschreiben können (Profil in
    values/crowdsec.yaml.tftpl) - genau die Anforderung aus dem Konzept.
  EOT
  type        = list(string)
  default     = ["192.168.178.0/24"]
}

variable "ingress_public_port" {
  description = "Port von ingress-public auf der DMZ-Adresse. Muss zu cluster_ingress_port in vm/edge passen."
  type        = number
  default     = 443
}

variable "crowdsec_lapi_port" {
  description = "Port der CrowdSec-LAPI auf der DMZ-Adresse. Muss zu crowdsec_lapi_port in vm/edge passen."
  type        = number
  default     = 8443
}

variable "step_ca_port" {
  description = "Port der internen CA auf der DMZ-Adresse. Muss zu step_ca_port in vm/edge passen."
  type        = number
  default     = 9000
}

#
# Namen
#
variable "domain" {
  description = "Basisdomain. Nur für die internen Namen relevant - die öffentlichen Zertifikate holt die Edge-VM selbst."
  type        = string
  default     = "domain.de"
}

variable "ingress_public_server_name" {
  description = <<-EOT
    Name im Serverzertifikat von ingress-public. Muss exakt dem entsprechen,
    was in vm/edge als cluster_ingress_server_name steht - die Edge prüft das
    Zertifikat gegen diesen Namen, nicht gegen die IP.
  EOT
  type        = string
  default     = "ingress-public.internal"
}

variable "app_namespaces" {
  description = <<-EOT
    Namespaces für die Anwendungen, mit ihrer Zone.

      public   - erreichbar über ingress-public, also aus dem Internet.
                 Nur diese Namespaces dürfen ingressClassName: public
                 verwenden; erzwungen wird das von Kyverno.
      internal - nur über ingress-internal, also nur aus dem LAN.

    Die Zone ist damit kein Kommentar, sondern eine Kontrolle: Ein aus
    Nextcloud kopiertes Ingress-Manifest, das mit "public" bei Paperless
    landet, wird abgelehnt statt exponiert.
  EOT
  type = list(object({
    name = string
    zone = string
  }))
  default = [
    { name = "nextcloud", zone = "public" },
    { name = "immich", zone = "public" },
    { name = "paperless", zone = "internal" },
  ]

  validation {
    condition     = alltrue([for ns in var.app_namespaces : contains(["public", "internal"], ns.zone)])
    error_message = "zone muss public oder internal sein."
  }
}

#
# Chart-Versionen - gepinnt, damit Renovate sie verfolgen kann
#
variable "cert_manager_version" {
  description = "Chart-Version von cert-manager."
  type        = string
  default     = "v1.21.1"
}

variable "step_ca_chart_version" {
  description = "Chart-Version von step-certificates (interne CA)."
  type        = string
  default     = "1.30.1"
}

variable "traefik_chart_version" {
  description = "Chart-Version von Traefik. Die App-Version sollte nah an traefik_version in vm/edge liegen - zwei weit auseinanderliegende Proxys in derselben Kette sind eine Fehlerquelle."
  type        = string
  default     = "41.1.0"
}

variable "crowdsec_chart_version" {
  description = "Chart-Version von CrowdSec (LAPI plus Agent)."
  type        = string
  default     = "0.24.0"
}

variable "kyverno_chart_version" {
  description = "Chart-Version von Kyverno."
  type        = string
  default     = "3.8.2"
}

variable "step_cli_image" {
  description = <<-EOT
    Image mit step-cli. Holt und erneuert das Serverzertifikat von
    ingress-public - dasselbe Werkzeug, das auf der Edge-VM das
    Client-Zertifikat holt.
  EOT
  type        = string
  default     = "smallstep/step-cli:0.30.6"
}

#
# Betriebsschalter
#
variable "cert_lifetime" {
  description = <<-EOT
    Laufzeit der Zertifikate aus der internen CA. 24 h ist Entscheidung E5:
    Eine step-ca-Instanz stellt keine CRL aus, und Traefiks clientAuth prüft
    ohnehin keine Revokation - kurze Laufzeit ersetzt den fehlenden Rückruf.
  EOT
  type        = string
  default     = "24h"
}

variable "cert_renew_before" {
  description = "Ab welcher Restlaufzeit das Zertifikat von ingress-public erneuert wird. Der Puffer trägt fehlgeschlagene Versuche."
  type        = string
  default     = "8h"
}

variable "storage_class_path" {
  description = <<-EOT
    Verzeichnis auf dem Node, in dem local-path die PVCs anlegt.

    Bewusst auf der Systemplatte (/var überlebt bei Talos einen Reboot, nicht
    aber ein `talosctl reset`): Postgres über NFS ist laut Konzept eine Quelle
    für schwer auffindbare Korruption. Nutzerdaten (Fotos, Dokumente) gehören
    später auf einen eigenen NFS-Export vom Unraid-Array, nicht hierher.
  EOT
  type        = string
  default     = "/var/local-path-provisioner"
}

variable "crowdsec_collections" {
  description = <<-EOT
    Hub-Collections für den Agenten im Cluster. Zugeschnitten auf das, was
    hier anfällt: Anwendungslogs. Die Proxy-Collections laufen auf der
    Edge-VM - ein fehlgeschlagener Nextcloud-Login liefert HTTP 200 und ist
    aus Proxy-Sicht nicht erkennbar.
  EOT
  type        = list(string)
  default = [
    "crowdsecurity/nextcloud",
    "crowdsecurity/base-http-scenarios",
    "crowdsecurity/http-cve",
    "crowdsecurity/whitelist-good-actors",
  ]
}

variable "crowdsec_edge_machine_id" {
  description = "Name, unter dem der Agent der Edge-VM an der LAPI registriert wird. Muss zu vm_name in vm/edge passen."
  type        = string
  default     = "edge1"
}

variable "internal_acme" {
  description = <<-EOT
    ACME-Aussteller für die internen Namen (ingress-internal).

    Standardmäßig aus: Dann bekommen die internen Dienste ihre Zertifikate von
    der internen CA, und der Browser warnt, solange das Wurzelzertifikat nicht
    importiert ist. Das ist ein bewusster Zwischenstand, kein Endzustand.

    Eingeschaltet wird ein ACME-ClusterIssuer mit acme-dns-Solver - dieselbe
    Technik wie auf der Edge-VM, aber mit eigenem Konto: Die Trennung der
    beiden ACME-Clients ist Entscheidung E4 und hebt sich sonst auf.

    Das Secret mit den acme-dns-Kontodaten (Schlüssel: acmedns.json) muss vor
    dem Anwenden im Namespace cert-manager liegen.
  EOT
  type = object({
    enabled             = bool
    email               = optional(string, "")
    server              = optional(string, "https://acme-v02.api.letsencrypt.org/directory")
    acme_dns_host       = optional(string, "")
    acme_dns_secret     = optional(string, "acme-dns-internal")
    acme_dns_secret_key = optional(string, "acmedns.json")
  })
  default = {
    enabled = false
  }
}
