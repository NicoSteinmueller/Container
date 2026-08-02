# Inbetriebnahme auf Unraid

Der Weg von einem leeren Unraid-Host zu Immich und Nextcloud im Internet.
Reihenfolge einhalten — die Portfreigabe kommt **zuletzt**, nicht zuerst.

Ausführlich steht alles in [../vm/edge/README.md](../vm/edge/README.md),
[../vm/talos/README.md](../vm/talos/README.md) und
[platform/README.md](platform/README.md); das hier ist der Ablauf.

## 0. Voraussetzungen auf dem Unraid-Host

| Punkt | Prüfen mit |
|---|---|
| VM-Manager aktiv (Settings → VM Manager → Enable VMs: Yes) | `ssh root@unraid virsh list --all` |
| Bridge `br0` vorhanden (Settings → Network → Bridging aktiv) | `ssh root@unraid ip -br link` |
| Storage-Pool für die VMs, meist `default` auf `/mnt/user/domains` | `ssh root@unraid virsh pool-list` |
| ~120 GB frei in `/mnt/user/domains` | `ssh root@unraid df -h /mnt/user/domains` |
| RAM-Budget: 1,5 GB Edge + 10 GB Talos + ~2 GB Unraid = knapp bei 16 GB | Dashboard |

**SSH-Key nach Unraid.** Terraform spricht über `qemu+ssh://root@…` mit
libvirt. Unraid bootet vom USB-Stick, `/root` ist ein RAM-Dateisystem — ein
`ssh-copy-id` überlebt den nächsten Neustart nicht. Der Key gehört deshalb
zusätzlich nach `/boot/config/ssh/root.pubkeys` — Unraid kopiert die Datei ab
6.10 beim Booten nach `/root/.ssh/authorized_keys`. Bei älteren Versionen
stattdessen eine Zeile in `/boot/config/go`:

```bash
ssh-copy-id root@192.168.178.3                     # für jetzt
ssh root@192.168.178.3 'mkdir -p /boot/config/ssh && \
  cat /root/.ssh/authorized_keys >> /boot/config/ssh/root.pubkeys'   # für später
```

**Auf der Arbeitsstation:** `terraform`, `talosctl`, `kubectl`, `helm`.

**Adressen festlegen** (Beispiel, muss zum eigenen Netz passen):

| Was | Adresse | Wo eingetragen |
|---|---|---|
| Unraid | 192.168.178.3 | — |
| Interner Resolver (AdGuard) | 192.168.178.2 | `dns_servers` in beiden Modulen |
| Edge-VM, LAN | 192.168.178.20 | `lan_ip`, Ziel der Fritzbox-Freigabe |
| Talos-Node, LAN | 192.168.178.21 | `lan_ip` in vm/talos |
| Edge-VM, DMZ | 10.10.20.2 | `edge_dmz_ip` |
| Talos-Node, DMZ | 10.10.20.3 | `node_dmz_ip` / `cluster_ingress_ip` |

Beide LAN-Adressen müssen **außerhalb** des Fritzbox-DHCP-Bereichs liegen.

## 1. Edge-VM

```bash
cd vm/edge
cp terraform.tfvars.example terraform.tfvars
```

In `terraform.tfvars` mindestens setzen:

```hcl
libvirt_uri         = "qemu+ssh://root@192.168.178.3/system"
lan_bridge          = "br0"
lan_ip              = "192.168.178.20"
lan_gateway         = "192.168.178.1"
dns_servers         = ["192.168.178.2"]
ssh_authorized_keys = ["ssh-ed25519 AAAA... nico"]
admin_sources       = ["192.168.178.0/24"]

domain = "domain.de"
public_services = [
  { name = "immich", subdomain = "immich", strict_paths = ["/api/auth"] },
  { name = "cloud",  subdomain = "cloud",  strict_paths = ["/login"], relaxed_paths = ["/remote.php"] },
]
acme_email = "post@domain.de"
# Für die ersten Läufe:
acme_ca_server = "https://acme-staging-v02.api.letsencrypt.org/directory"
```

```bash
terraform init && terraform apply
ssh edge@192.168.178.20 cloud-init status --wait     # dauert ein paar Minuten
verify/assert-ruleset.sh
verify/egress-test.sh
```

Damit steht die VM, das isolierte Netz `edge-dmz` existiert auf dem Host —
und noch kommt niemand von außen hinein.

## 2. Talos-Node

```bash
cd ../talos
cp terraform.tfvars.example terraform.tfvars
```

Anpassen: `libvirt_uri` (wie oben), `lan_bridge = "br0"`, `lan_ip`,
`lan_gateway`, `dns_servers`, `admin_sources`.

```bash
terraform init && terraform apply       # 5-10 Minuten, wartet auf einen gesunden Cluster
export TALOSCONFIG=$PWD/talosconfig KUBECONFIG=$PWD/kubeconfig
kubectl get nodes -o wide               # Ready, INTERNAL-IP 192.168.178.21
verify/assert-cluster.sh
```

Wenn der Apply hängt: `virsh -c qemu+ssh://root@192.168.178.3/system console homelab-cp1`.

## 3. Cluster ausstatten

```bash
cd ../../k8s/platform
cp terraform.tfvars.example terraform.tfvars    # dieselben Adressen eintragen
terraform init && terraform apply
```

Beim allerersten Lauf kann der Bootstrap-Job der CA noch nicht durch sein —
dann schlicht ein zweites Mal `terraform apply`.

```bash
verify/assert-platform.sh
terraform output bootstrap_schritte
```

## 4. Die drei Bootstrap-Schritte

Zugangsdaten kommen bewusst nicht aus Terraform. Der Reihe nach:

```bash
# a) Interne CA in vm/edge eintragen
kubectl -n step-ca exec sts/step-ca -- \
  step certificate fingerprint /home/step/certs/root_ca.crt
```

In `vm/edge/terraform.tfvars`:

```hcl
step_ca_url         = "https://10.10.20.3:9000"
step_ca_fingerprint = "<Ausgabe von oben>"
cluster_ingress_ip  = "10.10.20.3"
```

```bash
cd ../../vm/edge && terraform apply

# b) Client-Zertifikat der Edge (Token läuft nach Minuten ab)
../../k8s/platform/scripts/edge-token.sh edge1.dmz
ssh edge@192.168.178.20 sudo edge-mtls-bootstrap '<token>'

# c) CrowdSec-Zugangsdaten
../../k8s/platform/scripts/edge-register.sh
# das Skript gibt den fertigen edge-crowdsec-connect-Aufruf für die VM aus
```

Danach in `vm/edge/terraform.tfvars` `crowdsec_bouncer_armed = true` setzen
und `terraform apply`. Der **Firewall**-Bouncer bleibt noch aus.

## 5. Erst jetzt: DNS und Fritzbox

1. `immich.domain.de` und `cloud.domain.de` per DynDNS auf die eigene IP —
   über den DNS-Anbieter, nicht über MyFRITZ!.
2. ACME-DNS-Instanz aufsetzen, `_acme-challenge`-CNAMEs anlegen
   (`terraform output acme_challenge_cnames` in `vm/edge`), Zertifikate erst
   gegen Staging holen, dann `acme_ca_server` auf Produktion umstellen.
3. Fritzbox: **nur 443/TCP** auf `192.168.178.20`. Port 80 bleibt zu.
4. **IPv6 getrennt prüfen** — „Host komplett freigeben" öffnet mehr als
   gedacht. UPnP aus, MyFRITZ!-Fernzugriff aus.

```bash
vm/edge/verify/proxy-test.sh cloud.domain.de
```

Die beiden wichtigsten Proben darin: Ein gefälschter `X-Forwarded-For` darf im
Log **nicht** auftauchen, und ein fremder Hostname muss im TLS-Handshake enden.

## 6. Anwendungen

Namespaces, NetworkPolicies und IngressClasses stehen schon. Ein Ingress
braucht nur noch die richtige Klasse:

```yaml
spec:
  ingressClassName: public     # nextcloud, immich  -> aus dem Internet
  # ingressClassName: internal # paperless          -> nur aus dem LAN
```

`public` in einem internen Namespace lehnt Kyverno ab — das ist Absicht und
getestet.

## 7. Scharfschalten (nach 1-2 Wochen)

```bash
kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli alerts list
ssh edge@192.168.178.20 sudo edge-crowdsec-connect --arm-firewall-bouncer
```

Danach in `vm/edge/terraform.tfvars` den Egress zumachen: Counter lesen
(`sudo nft list table inet edge`), `egress_targets` füllen,
`egress_open = false`, `terraform apply`, `verify/egress-test.sh`.

## Wenn etwas klemmt

| Symptom | Erste Stelle |
|---|---|
| `terraform apply` kommt nicht an libvirt | `virsh -c qemu+ssh://root@unraid/system list` von Hand |
| Edge-VM ohne Netz | `virsh console edge1`, MACs und `lan_bridge` prüfen |
| Talos bleibt NotReady | `kubectl -n kube-system get pods -l k8s-app=cilium`, `talosctl -n … dmesg` |
| Node nicht mehr erreichbar | `admin_sources` falsch → serielle Konsole, siehe vm/talos/README.md |
| Edge erreicht den Cluster nicht | `vm/edge/verify/egress-test.sh`, dann `talosctl -n … get nftableschains` |
| ACME schlägt fehl | Zeit (NTP), CNAME-Delegation, Staging-Verzeichnis verwenden |
| Ingress antwortet nicht | `kubectl -n traefik-public logs deploy/traefik-public`, Zertifikat im Container `pki-renew` ansehen |
| Alles tot nach Policy-Änderung | `kubectl -n traefik-public delete networkpolicy allow-from-edge` |

## Was danach noch fehlt

Kein Backup, keine NFS-Exporte vom Array, kein Monitoring — siehe „Was noch
offen ist" in [platform/README.md](platform/README.md) und „Nächste Schritte"
im [Sicherheitskonzept](homelab-sicherheitskonzept.html).

Und: Die drei `terraform.tfstate`-Dateien enthalten die Cluster-PKI. Sie
liegen nur auf der Arbeitsstation und gehören verschlüsselt gesichert — wer
sie hat, hat den Cluster.
