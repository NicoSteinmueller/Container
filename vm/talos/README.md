# Talos-VM

Zone 3 des Sicherheitskonzepts
([../../k8s/homelab-sicherheitskonzept.html](../../k8s/homelab-sicherheitskonzept.html),
Abschnitt „Talos-Cluster"): ein Single-Node-Cluster mit zwei Beinen — eines im
Heimnetz, eines in dem isolierten Segment, in dem die Edge-VM steht.

Dieses Modul baut die Maschine und den Cluster. Was im Cluster läuft — die
beiden Ingress-Controller, die interne CA, CrowdSec, Kyverno — steht in
[../../k8s/platform](../../k8s/platform).

## Was hier entsteht

| Ressource | Wert |
|---|---|
| VM | `homelab-cp1`, 4 vCPU, 4 GB RAM (wächst mit, siehe unten), 100 GB Disk, UEFI/q35 |
| LAN-Bein | `192.168.178.222` per macvtap auf `bond0` — Talos-API, Kubernetes-API, `ingress-internal` |
| DMZ-Bein | `10.10.20.3` im Netz `edge-dmz` — `ingress-public`, CrowdSec-LAPI, step-ca |
| OS | Talos Linux, Version gepinnt in [variables.tf](variables.tf) |
| CNI | Cilium mit kube-proxy-Replacement, als Inline-Manifest in der Machine-Config |
| Firewall | Talos-Ingress-Firewall, Default-Aktion `block` |
| Zugang | Talos-API und Kubernetes-API nur aus `admin_sources` |

Und was **nicht** entsteht: kein SSH (gibt es in Talos nicht), keine Shell,
kein Paketmanager, kein VNC auf dem Hypervisor, kein Discovery-Dienst nach
außen, kein IPv6.

Das DMZ-Netz legt **[../edge](../edge)** an — isoliert, ohne Adresse auf dem
Host, ohne DHCP. Dieses Modul hängt sich nur hinein. Deshalb: erst `vm/edge`,
dann `vm/talos`.

## Der RAM wächst mit den Diensten

Das Konzept nennt 10 GB für diese VM. Das ist der Endausbau — der Zustand,
in dem Nextcloud, Immich und Paperless im Cluster laufen. Beim Bootstrap
laufen sie aber noch als Container auf dem Host, und ihr Speicher ist damit
schlicht nicht frei:

| | |
|---|---|
| Host gesamt | 16 GB |
| Docker-Container | ~7,5 GB |
| Edge-VM | 1,5 GB |
| bleibt | ~5 GB |

Deshalb startet dieses Modul mit **4 GB** — genug für Talos, Cilium und den
kompletten Plattform-Stack aus [../../k8s/platform](../../k8s/platform), aber
noch ohne Nutzlast.

Der Weg nach oben, pro migriertem Dienst:

```bash
# 1. Dienst im Cluster hochziehen und prüfen
# 2. Container auf dem Host stoppen — erst dann ist der Speicher frei
ssh root@unraid docker stop nextcloud nextcloud_postgres nextcloud_redis

# 3. RAM nachziehen
vim terraform.tfvars      # vm_memory_mib = 6144
terraform apply           # libvirt_domain.cp1 will be updated in-place

# 4. Wirksam beim nächsten Start
talosctl -n <lan_ip> shutdown
ssh root@unraid virsh start homelab-cp1
```

`memory` ist **nicht** ForceNew — der Apply schreibt nur die Domain-Definition
neu, die VM wird nicht ersetzt und die Disk bleibt. Aber libvirt kann die
Obergrenze einer laufenden Domain nicht anheben, also braucht es den Neustart.

Die Reihenfolge in Schritt 2 und 3 ist nicht beliebig: Wer erst den RAM erhöht
und dann den Container stoppt, lässt beide gleichzeitig um denselben Speicher
konkurrieren — auf einem Host ohne Swap endet das im OOM-Killer, und der trifft
statistisch den größten Prozess. Das ist dann qemu.

## Voraussetzungen

- `terraform`, `talosctl`, `kubectl`, `libvirt`/`qemu-kvm`
- Ein Weg ins Heimnetz: `lan_bridge` oder `lan_macvtap_dev` - dieselbe
  Einstellung wie in `vm/edge`
- `vm/edge` ist angewendet — von dort kommen das libvirt-Netz `edge-dmz` und
  der Storage-Pool, den dieses Modul mitbenutzt (`libvirt_pool` muss in beiden
  Modulen gleich lauten)
- Eine freie feste Adresse im Heimnetz außerhalb des Fritzbox-DHCP-Bereichs
- UEFI-Firmware, die libvirt findet. Auf Unraid scheitert die automatische
  Auswahl (fehlende NVRAM-Vorlage) — dort `efi_loader` und
  `efi_vars_template` setzen, siehe
  [../../k8s/INBETRIEBNAHME.md](../../k8s/INBETRIEBNAHME.md)

## Erstellen

```bash
cd vm/talos
cp terraform.tfvars.example terraform.tfvars   # Adressen anpassen
terraform init
terraform apply
```

`terraform apply` ist erst fertig, wenn der Cluster tatsächlich gesund ist —
`data.talos_cluster_health` wartet auf eine Ready-Node inklusive CNI. Der
gesamte Lauf dauert je nach Host fünf bis zehn Minuten; zusehen kann man über
die serielle Konsole:

```bash
virsh -c qemu:///system console homelab-cp1
```

Danach:

```bash
export TALOSCONFIG=$PWD/talosconfig
export KUBECONFIG=$PWD/kubeconfig
talosctl -n 192.168.178.222 health
kubectl get nodes -o wide
verify/assert-cluster.sh
```

`terraform output naechste_schritte` gibt dieselbe Liste mit den konkreten
Adressen dieses Stands aus.

## Die zwei Beine

Das ist der Kern dieses Moduls, und es ist derselbe Gedanke wie bei der
Edge-VM: Nicht die Topologie trennt, sondern was auf welcher Adresse lauscht.

| Adresse | Was hängt daran | Wer darf hin |
|---|---|---|
| `192.168.178.222:50000` | Talos-API | nur `admin_sources` |
| `192.168.178.222:6443` | Kubernetes-API | `admin_sources` und das Pod-Netz |
| `192.168.178.222:443` | `ingress-internal` | das Heimnetz |
| `10.10.20.3:443` | `ingress-public` | nur `10.10.20.2` (Edge-VM) |
| `10.10.20.3:8443` | CrowdSec-LAPI | nur `10.10.20.2` |
| `10.10.20.3:9000` | step-ca | nur `10.10.20.2` |

Durchgesetzt wird das doppelt:

1. **Bindung.** Die Ingress-Controller verwenden `hostPort` zusammen mit
   `hostIP` — Cilium wertet beides im eBPF-Datapath aus und exponiert den Pod
   dann ausschließlich auf der angegebenen Adresse. Ohne `hostIP` läge er auf
   allen Node-IPs, und die Trennung zwischen öffentlichem und privatem Ingress
   wäre aufgehoben. Genau davor warnt das Konzept („Service-Bindung prüfen,
   nicht annehmen").
2. **Ingress-Firewall.** [patches/ingress-firewall.yaml.tftpl](patches/ingress-firewall.yaml.tftpl)
   setzt die Default-Aktion auf `block` und erlaubt jeden Port einzeln, mit
   Quelladresse. Die Bindung allein würde jeden im DMZ-Segment durchlassen —
   und das Segment ist die Zone, in der die exponierte Maschine steht.

Die Abnahme dazu steht in [verify/assert-cluster.sh](verify/assert-cluster.sh):
Auf `192.168.178.222:443` muss `ingress-internal` antworten, erkennbar am
Serverzertifikat — steht dort `ingress-public.internal`, greift die Bindung
nicht.

`ss -lntp` hilft dabei übrigens **nicht**: Cilium bildet hostPort im
eBPF-Datapath ab, es gibt keinen lauschenden Socket. Maßgeblich ist
`cilium-dbg service list`.

## Cilium als Inline-Manifest

Ungewöhnlich, deshalb die Begründung: Ohne CNI bleibt der Node NotReady, und
dann kann `terraform apply` nicht auf einen gesunden Cluster warten — es käme
ein halb fertiger Cluster als Erfolg zurück. Als Teil der Machine-Config
gehört das CNI zur Maschine, nicht zur Anwendungsschicht.

Terraform rendert das Chart lokal (`data "helm_template"`, kein
Cluster-Zugriff) und legt das Ergebnis in `cluster.inlineManifests`. Rund
70 KB YAML, die in der Machine-Config landen.

Der Preis: Ein Cilium-Update ist eine Config-Änderung mit `terraform apply`
statt eines `helm upgrade`. Wer das nicht will, entfernt den letzten Patch in
[main.tf](main.tf) und installiert Cilium aus `k8s/platform` — dann muss aber
`data.talos_cluster_health` weichen, sonst schlägt der erste Apply fehl.

## Wenn der Zugang weg ist

Die Ingress-Firewall kann aussperren. Steht in `admin_sources` die falsche
Quelle, ist der Node über `talosctl` nicht mehr erreichbar — und Talos hat
kein SSH, mit dem man das reparieren könnte.

Der Weg zurück:

```bash
# 1. Konsole auf dem Hypervisor - der einzige Zugang, der nicht über das Netz geht
virsh -c qemu:///system console homelab-cp1

# 2. Wenn der Node läuft, aber nicht erreichbar ist: von der ISO in den
#    Maintenance-Mode booten (Konsole, Reboot, Bootreihenfolge auf cdrom),
#    dort hört apid ohne Ingress-Firewall.
# 3. Config korrigieren und erneut anwenden:
terraform apply
```

Deshalb bleibt die serielle Konsole im Modul, und deshalb gibt es kein VNC:
Ein Notzugang, der aus dem Netz erreichbar wäre, ist kein Notzugang, sondern
eine zweite Angriffsfläche.

Für die Inbetriebnahme gibt es zusätzlich `ingress_firewall_enforced = false`.
Dann stehen die Regeln zwar im Kernel, die Default-Aktion bleibt aber
`accept`. Der Schalter gehört nach der Abnahme wieder auf `true` —
`verify/assert-cluster.sh` sagt es, solange er es nicht ist.

## Bewusste Entscheidungen

**Ein Node, Control Plane und Workloads zusammen.** `allowSchedulingOnControlPlanes: true`.
Bei einem Blech ist alles andere Selbstbetrug: Ein zweiter Node hätte dieselbe
Fehlerdomäne. Kommen echte Worker dazu, gehört der Patch entfernt.

**etcd nur im LAN-Segment.** `advertisedSubnets` und `listenSubnets` stehen auf
dem Heimnetz. Ohne diese Einschränkung sucht sich etcd bei zwei Beinen eine
Adresse aus — und im schlechteren Fall ist das die DMZ-Adresse, also die
Seite, auf der die exponierte VM steht.

**Discovery komplett aus.** Der Service-Registry-Weg meldet Cluster-Metadaten
an `discovery.talos.dev`; die Kubernetes-Registry ist deprecated und erzeugt
mit Kubernetes 1.32+ eine Endlosschleife aus „nodes is forbidden"-Warnungen.
Nodes treten über ihre Machine-Config bei, nicht über Discovery. Ausführlich
in [../talos-test/patches/hardening.yaml](../talos-test/patches/hardening.yaml).

**PodSecurity clusterweit auf `restricted`.** Talos setzt ab Werk `baseline`.
Die Namespaces, die mehr brauchen — die beiden Ingress-Controller wegen
`hostPort`, CrowdSec wegen der Container-Logs, local-path wegen der
Helper-Pods —, tragen ihr eigenes Label und sind in
[../../k8s/platform/charts/homelab-base](../../k8s/platform/charts/homelab-base)
einzeln begründet.

**Kein Zugriff vom Cluster auf die Talos-API.** `kubernetesTalosAPIAccess`
bleibt aus. Der Cluster darf die Maschine nicht konfigurieren, auf der er
läuft — das ist die Grenze, hinter die ein Container-Escape nicht kommen soll.

**`ip_forward` bleibt an.** Anders als auf der Edge-VM: Ein Kubernetes-Node
ist per Definition ein Router für seine Pods. Die Grenze zwischen DMZ und LAN
zieht deshalb die Ingress-Firewall, nicht der Weiterleitungsschalter. Was das
nicht ist: eine Trennung auf Netzebene. Wer im Cluster Node-Rechte erlangt,
hat beide Beine — das steht so auch im Konzept unter Restrisiken.

**Kein `serverTLSBootstrap`.** Es klingt richtiger, als es ist: Ohne einen
Approver für die Kubelet-Serving-CSRs bleibt die Anforderung Pending, und
damit funktionieren `kubectl logs`, `exec` und jeder Metrics-Abruf nicht mehr.

## Betrieb

```bash
export TALOSCONFIG=$PWD/talosconfig KUBECONFIG=$PWD/kubeconfig

talosctl -n 192.168.178.222 health
talosctl -n 192.168.178.222 dmesg -f              # Kernel-Log
talosctl -n 192.168.178.222 get addresses         # beide Beine
talosctl -n 192.168.178.222 get nftableschains    # die Ingress-Firewall
talosctl -n 192.168.178.222 logs kubelet

# Cilium
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose
kubectl -n kube-system exec ds/cilium -- cilium-dbg service list   # hostPort-Bindungen
kubectl -n kube-system exec ds/cilium -- hubble observe --follow

# Nach jeder Änderung
terraform apply && verify/assert-cluster.sh
```

**Talos-Upgrade.** Immer mit derselben Schematic-ID, sonst verschwinden die
System-Extensions:

```bash
terraform output installer_image
talosctl -n 192.168.178.222 upgrade --image <installer_image>
```

**Kubernetes-Upgrade** getrennt davon:

```bash
talosctl -n 192.168.178.222 upgrade-k8s --to 1.36.4
```

Danach `kubernetes_version` in [variables.tf](variables.tf) nachziehen, damit
Repo und Cluster nicht auseinanderlaufen.

## Aufräumen

```bash
terraform destroy
```

Entfernt VM, Disk und ISO. Das DMZ-Netz bleibt (es gehört `vm/edge`), und die
Daten auf `/var/local-path-provisioner` gehen mit der Disk verloren — vor dem
Destroy also die Backups prüfen. Ein ungetestetes Backup ist eine Annahme.
