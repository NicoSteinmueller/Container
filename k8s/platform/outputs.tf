output "step_ca_root" {
  description = "Wurzelzertifikat der internen CA (öffentlich). Ansehen: terraform output -raw step_ca_root"
  value       = data.kubernetes_config_map.step_ca_certs.data["root_ca.crt"]
}

output "step_ca_fingerprint_cmd" {
  description = <<-EOT
    Befehl für den Fingerprint des Wurzelzertifikats. Der Wert gehört in
    vm/edge/terraform.tfvars als step_ca_fingerprint - ohne ihn vertraut die
    Edge beim Bootstrap blind dem, was auf der CA-Adresse antwortet.
  EOT
  value       = "kubectl -n step-ca exec sts/step-ca -- step certificate fingerprint /home/step/certs/root_ca.crt"
}

output "edge_werte" {
  description = "Die Werte, die in vm/edge/terraform.tfvars stehen müssen, damit beide Seiten dieselbe Strecke meinen."
  value = {
    cluster_ingress_ip          = var.node_dmz_ip
    cluster_ingress_port        = var.ingress_public_port
    crowdsec_lapi_port          = var.crowdsec_lapi_port
    step_ca_url                 = "https://${var.node_dmz_ip}:${var.step_ca_port}"
    step_ca_port                = var.step_ca_port
    cluster_ingress_server_name = var.ingress_public_server_name
  }
}

output "public_namespaces" {
  description = "Namespaces, in denen ingressClassName: public zulässig ist. Überall sonst lehnt Kyverno ab."
  value       = local.public_namespaces
}

output "bootstrap_schritte" {
  description = "Was nach dem Anwenden von Hand passieren muss - Zugangsdaten kommen bewusst nicht aus Terraform."
  value       = <<-EOT
    1. Fingerprint der internen CA holen und in vm/edge/terraform.tfvars eintragen:
         kubectl -n step-ca exec sts/step-ca -- \
           step certificate fingerprint /home/step/certs/root_ca.crt

       Dazu passend:
         step_ca_url         = "https://${var.node_dmz_ip}:${var.step_ca_port}"
         cluster_ingress_ip  = "${var.node_dmz_ip}"
         cluster_ingress_server_name = "${var.ingress_public_server_name}"

       Danach in vm/edge: terraform apply

    2. Client-Zertifikat der Edge-VM (Token läuft nach Minuten ab):
         k8s/platform/scripts/edge-token.sh edge1.dmz
         # auf der Edge-VM:
         sudo edge-mtls-bootstrap <token>

    3. CrowdSec-Zugangsdaten für die Edge-VM:
         k8s/platform/scripts/edge-register.sh
       Das Skript legt Maschine und Bouncer an und gibt den fertigen
       edge-crowdsec-connect-Aufruf aus.

    4. Abnahme:
         k8s/platform/verify/assert-platform.sh
         vm/talos/verify/assert-cluster.sh
         vm/edge/verify/proxy-test.sh <öffentlicher-name>

    5. Erst danach in der Fritzbox 443/TCP auf die Edge-VM freigeben.
  EOT
}
