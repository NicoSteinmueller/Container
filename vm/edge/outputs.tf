output "vm_name" {
  description = "Name der libvirt-Domain. Serielle Konsole: virsh -c <uri> console <name>."
  value       = var.vm_name
}

output "lan_ip" {
  description = "Adresse der Edge-VM im Heimnetz. Ziel der Fritzbox-Portfreigabe."
  value       = var.lan_ip
}

output "edge_dmz_ip" {
  description = "Adresse der Edge-VM im DMZ-Segment. Diese Quell-IP gehört in die NetworkPolicy vor ingress-public und die CrowdSec-LAPI."
  value       = var.edge_dmz_ip
}

output "dmz_bridge" {
  description = "Linux-Bridge des DMZ-Segments. Das zweite Bein des Talos-Nodes muss hier hinein."
  value       = var.dmz_bridge
}

output "ssh_target" {
  description = "Ziel für ssh und die Skripte unter verify/."
  value       = "${var.admin_user}@${var.lan_ip}"
}

output "nftables_ruleset" {
  description = <<-EOT
    Der gerenderte Regelsatz. verify/assert-ruleset.sh vergleicht ihn gegen
    /etc/nftables.conf und gegen den tatsächlich geladenen Zustand.
    Lokal ansehen: terraform output -raw nftables_ruleset
  EOT
  value       = local.nftables_ruleset
}

output "sshd_config" {
  description = "Die gerenderte sshd-Ergänzung. Ebenfalls Vergleichsbasis für verify/assert-ruleset.sh."
  value       = local.sshd_config
}

#
# Werte, die verify/egress-test.sh braucht - und die auf der Cluster-Seite in
# NetworkPolicy und Ingress-Bindung noch einmal auftauchen.
#
output "cluster_ingress_ip" {
  description = "Adresse von ingress-public im DMZ-Segment."
  value       = var.cluster_ingress_ip
}

output "cluster_ingress_port" {
  description = "Port von ingress-public."
  value       = var.cluster_ingress_port
}

output "crowdsec_lapi_port" {
  description = "Port der CrowdSec-LAPI im Cluster."
  value       = var.crowdsec_lapi_port
}

output "lan_gateway" {
  description = "Default-Gateway im Heimnetz. Für die Egress-Probe: muss von der Edge-VM aus gesperrt sein, außer auf den freigegebenen Diensten."
  value       = var.lan_gateway
}

output "dns_server" {
  description = "Erster interner Resolver - das einzige erlaubte DNS-Ziel."
  value       = var.dns_servers[0]
}

output "egress_open" {
  description = "Zeigt an, ob der Egress noch im Bootstrap-Zustand ist (true = beliebige öffentliche Ziele erlaubt)."
  value       = var.egress_open
}

output "public_https_port" {
  description = "Port, den die Fritzbox weiterreicht."
  value       = var.public_https_port
}

output "public_hosts" {
  description = "Die öffentlichen Namen, für die Traefik ein Zertifikat holt. Für jeden davon braucht es einen _acme-challenge-CNAME auf die ACME-DNS-Instanz."
  value       = [for s in local.services : s.host]
}

output "acme_challenge_cnames" {
  description = "Die DNS-Einträge, die in der Zone stehen müssen, bevor ein Zertifikat ausgestellt werden kann. Ziel steht in den acme-dns-Kontodaten auf der VM."
  value       = [for s in local.services : "_acme-challenge.${s.host} CNAME <subdomain>.<acme-dns-instanz>"]
}

output "stack_status" {
  description = "Wie weit die Verarbeitungskette scharf ist."
  value = {
    stack_installiert       = var.stack_enabled
    crowdsec_installiert    = var.stack_enabled && var.crowdsec_enabled
    crowdsec_in_den_routern = var.stack_enabled && var.crowdsec_enabled && var.crowdsec_bouncer_armed
    interne_ca              = var.step_ca_url != "" && var.step_ca_fingerprint != ""
    oeffentliche_dienste    = length(var.public_services)
  }
}

output "cert_common_name" {
  description = "Common Name des mTLS-Client-Zertifikats. Damit im Cluster das Token erzeugen: step ca token <name>."
  value       = local.cert_common_name
}

output "naechste_schritte" {
  description = "Reihenfolge der Inbetriebnahme. Jeder Schritt hat eine Abnahme - die Kette wird von unten nach oben scharf."
  value       = <<-EOT
    1. Erster Boot abwarten (cloud-init status --wait), dann:
         vm/edge/verify/assert-ruleset.sh
         vm/edge/verify/egress-test.sh
    2. Talos-Node ein zweites Bein in die Bridge ${var.dmz_bridge} geben,
       ingress-public an ${var.cluster_ingress_ip} binden und die Bindung mit
       `ss -lntp` auf dem Node prüfen. Ein Verbindungsversuch aus dem LAN muss
       scheitern.
    3. ACME-DNS-Instanz aufsetzen, für jeden öffentlichen Namen einen
       _acme-challenge-CNAME anlegen (siehe Output acme_challenge_cnames) und
       prüfen, dass die Edge-Credentials die produktive Zone nicht schreiben
       können. Erste Läufe gegen das ACME-Staging-Verzeichnis.
    4. Fritzbox: ${var.public_https_port}/TCP auf ${var.lan_ip} freigeben. Port 80 bleibt zu.
       IPv6 getrennt prüfen - "Host komplett freigeben" öffnet mehr als gedacht.
       Danach: vm/edge/verify/proxy-test.sh <öffentlicher-name>
    5. step-ca im Cluster aufsetzen, step_ca_url und step_ca_fingerprint
       setzen, `terraform apply`, dann auf der VM:
         step ca token ${local.cert_common_name}   # im Cluster
         sudo edge-mtls-bootstrap <token>          # auf der Edge
       Erneuerung über mindestens zwei Zyklen beobachten.
    6. CrowdSec-LAPI im Cluster, dann auf der VM edge-crowdsec-connect mit
       Agent-Passwort und Bouncer-Keys. Anschließend crowdsec_bouncer_armed
       auf true und `terraform apply`.
    7. Ein bis zwei Wochen `cscli alerts list` auswerten, dann
       `sudo edge-crowdsec-connect --arm-firewall-bouncer`.
    8. Zum Schluss egress_targets füllen und egress_open auf false setzen.
  EOT
}

output "stack_file_digests" {
  description = <<-EOT
    SHA256 jeder Datei, die dieses Modul zusätzlich auf die VM legt.
    Vergleichsbasis für verify/assert-ruleset.sh: Damit fällt auf, wenn jemand
    Traefik- oder CrowdSec-Konfiguration auf der Maschine bearbeitet hat statt
    im Repo. Die Datei des Firewall-Bouncers steht bewusst nur im
    Staging-Verzeichnis - die aktive Kopie trägt den eingetragenen API-Key und
    weicht deshalb zwangsläufig ab.
  EOT
  value       = { for path, f in local.stack_files : path => sha256(f.content) }
}
