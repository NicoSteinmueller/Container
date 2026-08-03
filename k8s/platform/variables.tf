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
  default     = "192.168.178.222"
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

variable "node_name" {
  description = <<-EOT
    Hostname des Nodes. Muss zu node_name in vm/talos passen (dort leer =
    <cluster_name>-cp1).

    Wird hier für kubelet-csr-approver gebraucht: Der Name steht im
    Zertifikatsantrag des Kubelets, und der Genehmiger prüft ihn gegen einen
    verankerten Ausdruck. Stimmt er nicht überein, bleibt der Antrag auf
    "Pending" - und damit funktionieren `kubectl logs` und `kubectl exec`
    nicht mehr.
  EOT
  type        = string
  default     = "homelab-cp1"
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

variable "headlamp_chart_version" {
  description = "Chart-Version von Headlamp (Cluster-Dashboard)."
  type        = string
  default     = "0.44.0"
}

variable "metrics_server_chart_version" {
  description = "Chart-Version von metrics-server. Quelle für `kubectl top` und die Auslastungsanzeigen im Dashboard."
  type        = string
  default     = "3.13.1"
}

variable "csr_approver_chart_version" {
  description = <<-EOT
    Chart-Version von kubelet-csr-approver. Genehmigt die
    Serverzertifikate des Kubelets und gehört untrennbar zu
    serverTLSBootstrap in vm/talos/patches/hardening.yaml - siehe
    values/kubelet-csr-approver.yaml.tftpl.
  EOT
  type        = string
  default     = "1.2.14"
}

variable "step_cli_image" {
  description = <<-EOT
    Image mit step-cli. Stellt im Namespace step-ca das Serverzertifikat von
    ingress-public aus - dasselbe Werkzeug, das auf der Edge-VM das
    Client-Zertifikat holt.
  EOT
  type        = string
  default     = "smallstep/step-cli:0.30.6"
}

variable "kubectl_image" {
  description = <<-EOT
    Image mit kubectl. Legt das ausgestellte Serverzertifikat als Secret in
    den Namespace von ingress-public - der Schritt, der das
    Provisioner-Passwort dort überflüssig macht.

    Das offizielle Image des Kubernetes-Projekts, bewusst nicht eines der
    verbreiteten Drittanbieter-Images: Es läuft mit den Rechten, ein Secret
    in einem fremden Namespace zu schreiben. Version passend zu
    kubernetes_version in vm/talos.
  EOT
  type        = string
  default     = "registry.k8s.io/kubectl:v1.36.3"
}

#
# Dashboard und Metriken
#
variable "dashboard" {
  description = <<-EOT
    Das Cluster-Dashboard (Headlamp), erreichbar über ingress-internal.

      enabled  - Namespace, Netzgrenzen, RBAC und die Release. Auf false
                 bleibt vom Dashboard nichts im Cluster zurück.
      host     - Name, unter dem es erreichbar ist. Leer bedeutet
                 dashboard.<domain>. Er muss im Heimnetz auf node_lan_ip
                 zeigen (AdGuard oder Fritzbox) und ist aus dem Internet
                 weder auflösbar noch erreichbar.
      admin_service_account
               - ein ServiceAccount mit cluster-admin, aber ohne Token. Wer
                 im Dashboard ändern will, erzeugt sich damit eines für eine
                 Stunde:

                   kubectl -n headlamp create token headlamp-admin --duration=1h

                 Auf false, wenn im Dashboard ausschließlich gelesen werden
                 soll - geändert wird dann nur per kubectl.

    Zur Anmeldung, weil das die eigentliche Kontrolle ist: Headlamp fragt
    beim Aufruf nach einem Token und spricht anschließend mit genau der
    Identität, zu der dieses Token gehört. "Nur im LAN erreichbar" ist hier
    also nicht die Absicherung - wer die Seite ohne Token aufruft, sieht
    nichts.
  EOT
  type = object({
    enabled               = optional(bool, true)
    host                  = optional(string, "")
    admin_service_account = optional(bool, true)
  })
  default = {}
}

variable "metrics_server_enabled" {
  description = <<-EOT
    metrics-server: Quelle für `kubectl top` und die Auslastungsanzeigen im
    Dashboard.

    Standardmäßig aus, und das ist eine Reihenfolge, keine Meinung:

    metrics-server setzt echte Kubelet-Serverzertifikate voraus, also
    kubelet_server_certs = true in vm/talos plus einen Neustart des Nodes.
    Solange das fehlt, prüft er ein selbstsigniertes Zertifikat, bleibt mit
    "x509: certificate signed by unknown authority" stehen und wird nie
    Ready - und weil die Release mit wait = true läuft, scheitert dann der
    ganze `terraform apply`.

    Der Genehmiger für die Zertifikate (kubelet-csr-approver) kommt dagegen
    immer aus diesem Modul, unabhängig von diesem Schalter: Er muss vor der
    Talos-Änderung im Cluster sein, nicht danach.

    Reihenfolge:

      1. vm/talos      terraform apply                    (Genehmiger fehlt noch)
      2. k8s/platform  terraform apply                    bringt den Genehmiger
      3. vm/talos      kubelet_server_certs = true, apply
      4.               talosctl -n <lan_ip> reboot
      5. k8s/platform  metrics_server_enabled = true, apply   <- diese Zeile

    Der verbreitete Ausweg --kubelet-insecure-tls steht bewusst nicht in den
    Werten; warum, steht in values/metrics-server.yaml.

    Das Dashboard läuft auch ohne - es fehlen dann nur die
    Auslastungsanzeigen.
  EOT
  type        = bool
  default     = false
}

variable "kubelet_cert_max_expiration_seconds" {
  description = "Obergrenze für die Laufzeit der Kubelet-Serverzertifikate, die kubelet-csr-approver genehmigt. Sieben Tage; das Kubelet erneuert von sich aus deutlich häufiger."
  type        = number
  default     = 604800
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
