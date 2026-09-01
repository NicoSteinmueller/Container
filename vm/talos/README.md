# Talos-Node

Ein Talos-Node mit Kubernetes, feste Adresse im LAN, erreichbar von der
Arbeitsstation.

Konkrete Werte — Host, Adressen, Interface, Pool — stehen in
`$HOMELAB_VALUES/vm/talos/terraform.tfvars`; hier nur Platzhalter

| | |
|---|---|
| VM | `<cluster_name>-cp1`, q35 mit UEFI, Dimensionierung aus den tfvars |
| Disks | `vda` System (Talos), `vdb` Daten — lokaler Cluster-Speicher |
| Adresse | `<node-ip>`, statisch — zugleich Kubernetes-API-Endpoint |
| Netz | macvtap auf `lan_macvtap_dev` |
| Image | Image Factory, Talos + `qemu-guest-agent` |
| CNI | Cilium, als Inline-Manifest in der Machine-Config — kein kube-proxy |
| Speicher | `local-path` auf `vdb` als Default, NFS zum Unraid-Host daneben |

Versionen und Größen sind in [variables.tf](variables.tf) gepinnt, damit ein
Neuaufbau dieselbe Version ergibt wie der laufende Cluster.

## Voraussetzungen

- `tofu`, `talosctl` und `helm` lokal, SSH als `root` auf den Host
  (`helm` nur zum Rendern des Cilium-Charts, es wird kein Cluster angefasst)
- VM-Manager aktiv, Storage-Pool geklärt:

  ```bash
  virsh --connect qemu+ssh://root@<host>/system pool-list --all
  ```

  Leere Liste → `manage_pool = true` und `pool_path` setzen. Pool schon da → `manage_pool = false`.
- Genug Speicher: `ssh root@<host> free -m`. Maßgeblich ist `available`, nicht `free`;

## Cluster erstellen

State **und** Werte liegen in Gitea

```bash
cd vm/talos
git -C "$HOMELAB_VALUES" pull
tf init
tf apply
```

`apply` kehrt erst zurück, wenn der Cluster gesund ist — `talos_cluster_health`
blockiert so lange. 10–20 Minuten, überwiegend ISO-Download und zwei Reboots:

1. Image Factory liefert ISO- und Installer-URL zur Schematic-ID
2. `helm template` rendert Cilium lokal — ohne Cluster-Zugriff
3. libvirt lädt die ISO in den Pool, legt Disk und VM an
4. VM bootet in den **Maintenance-Mode**, per `ip=`-Kernel-Parameter bereits
   unter `lan_ip`
5. Machine-Config rein → Talos installiert auf `install_disk`, rebootet
6. `talos_machine_bootstrap` initialisiert etcd, Talos rollt das
   Cilium-Inline-Manifest aus
7. Health-Check wartet auf einen gesunden Cluster

`kubeconfig` und `talosconfig` landen im Verzeichnis, beide in `.gitignore`.

## Die zweite Disk

`vdb` ist der lokale Speicher des Clusters — dort liegen Datenbanken und alles
andere, das `fsync` und Locking braucht. Talos legt darauf ein User-Volume an
und mountet es nach `/var/mnt/local-path`; daraus macht
[local-path-provisioner](../../k8s/flux/clusters/talos-cp1/local-path.yaml) die
Default-StorageClass.

Getrennt von der System-Disk, und zwar **nicht** wegen Geschwindigkeit — beide
qcow2-Dateien liegen auf derselben SSD des Hypervisors. Es geht um die
Kopplung: Auf der `EPHEMERAL`-Partition lägen Datenbanken sonst neben dem
containerd-Image-Cache und den Logs. Läuft sie voll, setzt das kubelet
`DiskPressure`, evictet Pods und räumt Images ab — und trifft die Datenbank mit.
Zwei Disks machen daraus zwei unabhängige Ausfälle.

Der Mountpfad ist nicht frei wählbar: Talos mountet User-Volumes immer unter
`/var/mnt/<name>` und leitet das Partitionslabel als `u-<name>` daraus ab. Der
Name steht in `local.local_path_volume` in [main.tf](main.tf) und muss mit
`nodePathMap` im Flux-Manifest zusammenpassen.

```bash
talosctl get disks                  # vda und vdb
talosctl get volumestatus           # u-local-path
talosctl get volumemountstatus      # /var/mnt/local-path
```

Zwei Dinge, die beim ersten Mal überraschen:

- **Ein `apply` allein reicht nicht.** libvirt hängt eine neue Disk nicht an
  eine laufende Maschine an. Nach dem `apply` gehört die VM einmal neu
  gestartet, sonst findet der `diskSelector` nichts:

  ```bash
  ../../tools/tf apply
  talosctl -n <node-ip> shutdown
  virsh -c "qemu+ssh://root@<host>/system" start <cluster_name>-cp1
  ```

- **`vm_data_disk_gib` nachträglich zu ändern, ersetzt das Volume.** Terraform
  zerstört es und legt ein leeres an; der Inhalt ist weg. Deshalb großzügig
  wählen — qcow2 ist dünn alloziert, der Platz wird erst belegt, wenn er
  gebraucht wird.

Und der Vorbehalt, der dazugehört: Diese Disk ist **kein Backup und ersetzt
keins**. `tofu destroy` nimmt sie mit. Ein Sicherungsweg aus dem Cluster heraus
steht noch aus; wenn er kommt, gehört er nach Kopia auf dem Unraid-Host — bei
Datenbanken als Dump und nicht als Dateikopie.

## Zugang

```bash
cd vm/talos
export TALOSCONFIG=$PWD/talosconfig
export KUBECONFIG=$PWD/kubeconfig

talosctl health
kubectl get nodes -o wide
```

## Ingress-Firewall

Der Node blockt eingehenden Verkehr an seine eigenen Dienste, bis auf das,
was [patches/firewall.yaml.tftpl](patches/firewall.yaml.tftpl) freigibt. Wer
an Talos-API und kube-apiserver darf, steht in `admin_sources`.

**Sie schützt den Host, nicht den Cluster.** Verkehr zwischen Pods und
Services läuft daran vorbei — dafür sind die NetworkPolicies zuständig. Und
ob die Regeln den LoadBalancer-Verkehr überhaupt sehen, ist offen: Cilium
verarbeitet den in eBPF und kann Netfilter umgehen. Die Regel `ingress-ports`
hält 80/443 deshalb bedingungslos offen — sie sichert nichts ab, sie sorgt
dafür, dass die Antwort auf diese Frage keine Rolle spielt.

Gemessen von einer Adresse aus `admin_sources`, während die Regeln standen:

| Port | | |
|---|---|---|
| 50000, 6443, 10250 | offen | apid, kube-apiserver, Kubelet |
| 2379, 2380 | geblockt | etcd — vorher LAN-weit erreichbar |
| 4244, 9963, 9964 | geblockt | Hubble und Metrik-Endpunkte |

### Regeln ändern: erst `try`, dann `apply`

**Ein falscher Regelsatz sperrt dich aus der Talos-API aus.** Der Provider
kennt den try-Modus nicht — `tofu apply` schreibt die Regeln also endgültig.
Deshalb jede Änderung zuerst von Hand, mit automatischem Rückweg:

```bash
cd vm/talos
export TALOSCONFIG=$PWD/talosconfig

# Regeln so rendern, wie tofu sie schreiben würde
tofu console <<<'templatefile("${path.module}/patches/firewall.yaml.tftpl", { admin_sources = var.admin_sources, pod_subnet = var.pod_subnet, lan_cidr = var.lan_cidr })'

talosctl -n <lan_ip> patch machineconfig --dry-run  -p @firewall.yaml
talosctl -n <lan_ip> patch machineconfig --mode=try --timeout=150s -p @firewall.yaml
```

Talos nimmt die Änderung nach Ablauf des Timeouts von selbst zurück. In dem
Fenster nachmessen — die Kette muss stehen, und alles muss weiter antworten:

```bash
talosctl -n <lan_ip> get nftableschains     # darf nicht leer sein
talosctl -n <lan_ip> version                # Talos-API
kubectl get node                            # kube-apiserver
kubectl top node                            # Kubelet aus dem Pod-Netz
curl -sI https://<ein-dienst>               # Ingress über die LB-Adresse
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-health status
```

Erst wenn das durchläuft, `tofu apply`. Geht doch etwas schief und der
Rückweg über die API ist zu: serielle Konsole.

```bash
virsh -c "$libvirt_uri" console homelab-cp1
```

## Cilium

Das Chart wird beim `apply` lokal mit `helm template` gerendert und als
`cluster.inlineManifests` in die Machine-Config gelegt — Werte in
[values/cilium.yaml.tftpl](values/cilium.yaml.tftpl).

Der Grund ist die Reihenfolge: Ohne CNI bleibt der Node `NotReady`, und ein
`helm install` nach dem Bootstrap käme zu spät, um `talos_cluster_health`
etwas prüfen zu lassen — `apply` meldete einen halb fertigen Cluster als
Erfolg. Als Teil der Machine-Config gehört das CNI zur Maschine.

Was daran hängt:

- **kein kube-proxy** — Cilium macht Services im eBPF-Datapath
  (`kubeProxyReplacement`), passend dazu `cluster.proxy.disabled` in
  [patches/cluster.yaml.tftpl](patches/cluster.yaml.tftpl). Beides gehört
  zusammen.
- **API über KubePrism** (`localhost:7445`) statt über die Node-Adresse — der
  Weg verlässt den Node nicht und überlebt einen Adresswechsel.
- **Hubble** läuft im Agent, Relay und UI sind aus (`hubble_relay_enabled`,
  `hubble_ui_enabled`). Ohne Relay bleibt auch Hubble-TLS aus; das ist
  Absicht, denn die Zertifikate entstünden sonst bei *jedem* `helm template`
  neu und die Machine-Config wäre nie driftfrei.
- Die Machine-Config wächst dadurch um rund 60 KB gerendertes YAML.

### Eine Wertänderung ist mit `tofu apply` **nicht** im Cluster

Der wichtigste Fallstrick dieser Bauweise, und er meldet sich nicht von selbst:
**Talos schreibt geänderte Inline-Manifeste nicht auf bereits bestehende
Objekte durch.** Die Manifeste werden beim Bootstrap angelegt; danach hebt ein
`apply` zwar die interne Manifest-Ressource an, fasst die Objekte im Cluster
aber nicht mehr an.

Was man dann sieht — und was daran täuscht:

| | |
|---|---|
| `tofu plan` | `No changes` |
| `talosctl get mc v1alpha1` | enthält den neuen Wert |
| `talosctl get manifests` | `99-cilium` mit erhöhter `VERSION` |
| der laufende Cluster | **unverändert** |

Vier Anzeigen sagen „fertig", eine sagt die Wahrheit. Gemerkt haben wir es
beim Einschalten von `l2announcements`: Flag und Leases-RBAC standen in der
Machine-Config und fehlten im Cluster, und der Cilium-Pod war nicht einmal
neu gestartet.

Der Nachtrag ist ein Zweizeiler — der Inhalt kommt aus Talos selbst, ist also
exakt das, was dort hinterlegt ist:

```bash
talosctl -n <node-ip> get manifests 99-cilium -o yaml \
  | python3 -c 'import sys,yaml; print(yaml.safe_dump_all(yaml.safe_load(sys.stdin)["spec"]))' \
  | kubectl apply -f -
kubectl -n kube-system rollout status ds/cilium
```

Vorher lohnt `kubectl diff -f -` an derselben Stelle: Der Diff muss genau die
beabsichtigte Änderung zeigen und sonst nichts. Die Checksum-Annotation
`cilium.io/cilium-configmap-checksum` an DaemonSet und Operator ändert sich
mit — sie ist es, die den Rollout auslöst.

Zwei Dinge, die dabei auffallen und in Ordnung sind:

- `kubectl` warnt für jedes Objekt, dass die Annotation
  `last-applied-configuration` fehlt, und ergänzt sie. Erwartbar: Angelegt hat
  die Objekte Talos, nicht `kubectl apply`.
- Der Agent-Neustart unterbricht den Datapfad nicht spürbar — Cilium behält
  seine eBPF-Maps über einen Neustart hinweg.

**Nicht per `kubectl patch cm cilium-config` abkürzen.** Etliche Werte hängen
nicht nur an einem ConfigMap-Eintrag, sondern auch an RBAC: `l2announcements`
etwa braucht zusätzlich `coordination.k8s.io/leases`. Wer nur die ConfigMap
patcht, bekommt einen Agent, der die Funktion versucht und nicht darf — im Log
eine Endlosschleife aus `... is forbidden`, nach außen ein Dienst, der gesund
aussieht und nicht antwortet.

### NetworkPolicies gelten ab jetzt wirklich

Die unscheinbarste Folge des Wechsels, und die, die am ehesten überrascht:
**Talos' Flannel setzt NetworkPolicies gar nicht durch.** Es gibt keinen
Enforcer, `kubectl get netpol` zeigt Objekte an, und niemand fragt sie ab. Mit
Cilium werden sie zum ersten Mal ausgewertet.

Damit wird beim Umstieg jede Policy scharf, die bis dahin Dekoration war —
auch die, die man nie selbst geschrieben hat. Fremde Charts bringen
regelmäßig welche mit. Der erste Fall hier war die Flux-Status-Seite: Das
flux-operator-Chart legt eine `flux-operator-web` an, die Port 9080 nur
`from: namespaceSelector: {}` öffnet, also ausschließlich clusterinternen
Identitäten. Ein Browser im Heimnetz ist keine — der NodePort lief ins Leere
(siehe [k8s/flux/README.md](../../k8s/flux/README.md)).

Das Fehlerbild ist dabei irreführend: Ein Policy-Drop erzeugt **Timeout**, kein
`Connection refused`. Es sieht aus wie ein kaputtes Routing oder ein falscher
Port, obwohl Service und Endpoint stimmen. Die Unterscheidung liefert Hubble in
einer Zeile:

```bash
kubectl -n kube-system exec ds/cilium -- hubble observe --last 200 --type drop
```

```
192.168.x.x:32850 (world) <> flux-system/flux-operator-…:9080 (ID:9624)
  Policy denied DROPPED (TCP Flags: SYN)
```

`(world)` ist der Kern: Verkehr von außerhalb des Clusters trägt keine
Namespace- oder Pod-Identität. Regeln mit `namespaceSelector`, `podSelector`
oder `ipBlock` unterscheiden sich genau darin, ob sie ihn erfassen können.

Vor dem Umstieg lohnt deshalb eine Bestandsaufnahme dessen, was ab sofort gilt:

```bash
kubectl get netpol -A
```

### ipBlock und NodePort — gemessen, nicht angenommen

Für Verkehr, der von einem LAN-Client über einen NodePort hereinkommt, greifen
`ipBlock`-Regeln. Auf diesem Cluster nachgemessen: eine Policy mit
`ipBlock: <lan-cidr>` auf Port 9080 macht die Flux-Seite erreichbar (HTTP 200),
ohne sie bleibt es beim Drop. Hubble zeigt dabei die echte Client-Adresse — auf
einem Single-Node mit lokalem Backend wird nicht auf die Node-Adresse
maskiert.

Als Messung notiert, weil im Repo lange die gegenteilige Annahme stand — in
`k8s/whoami` als Begründung dafür, den NodePort ohne Quellen-Einschränkung zu
öffnen. Sie stammt aus einem anderen Fall: Cilium wertet `ipBlock` **nicht**
gegen die reservierten Identitäten `host` und `remote-node` aus — das betrifft
Pods, die den Node selbst ansprechen (Egress), und es stimmt dort. Auf
eingehenden LAN-Verkehr lässt es sich nicht übertragen, denn dessen Identität
ist `world`.

Der Vorbehalt bleibt: Sobald ein zweiter Node dazukommt und Verkehr über ihn
maskiert wird, kann die Quelle zu `remote-node` werden — und dann greift die
Regel nicht mehr. Für den Ein-Node-Cluster gilt das Gemessene.

### Umstellung eines Clusters, der schon mit Flannel läuft

Ein `apply` allein reicht dafür nicht. Talos rendert Flannel und kube-proxy
nach der Umstellung zwar nicht mehr, räumt die vorhandenen Objekte aber nicht
weg — und Cilium mit `kubeProxyReplacement` neben einem laufenden kube-proxy
ergibt zwei Datapfade für dieselben Services.

Bei einem leeren Single-Node-Cluster ist der Neuaufbau der ehrlichere Weg:

```bash
../../tools/tf destroy -var wait_for_health=false
../../tools/tf apply
```

Soll der Cluster stehen bleiben, gehören die Altlasten nach dem `apply` von
Hand weg, bevor Cilium gesund wird:

```bash
kubectl -n kube-system delete ds kube-proxy kube-flannel
kubectl -n kube-system delete cm kube-proxy
kubectl -n kube-system rollout restart ds cilium
```

Danach die Pods neu starten, die noch eine von Flannel vergebene Adresse
tragen — Cilium vergibt aus derselben `pod_subnet`, die alten Einträge kennt
es aber nicht.

## Diagnose ohne SSH

Es gibt keine Shell auf dem Node.

```bash
talosctl dmesg                      # Kernel- und Boot-Logs
talosctl logs kubelet               # Logs einzelner Talos-Dienste
talosctl services                   # Status aller Talos-Dienste
talosctl health --wait-timeout 10m
```

CNI-seitig:

```bash
kubectl -n kube-system get pods -l k8s-app=cilium
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --brief
kubectl -n kube-system exec ds/cilium -- hubble observe --follow
```

Bleibt der Node `NotReady`, ist fast immer das Inline-Manifest die Spur — es
kommt aus der Machine-Config, nicht aus einem Helm-Release:

```bash
talosctl get manifests
talosctl logs controller-runtime | grep -i manifest
```

Ist die API nicht erreichbar, bleibt die serielle Konsole — dorthin schreibt
Talos Boot und Installation vollständig:

```bash
virsh -c qemu+ssh://root@<host>/system console <cluster_name>-cp1
```

## Aufräumen

```bash
../../tools/tf destroy -var wait_for_health=false
```

Ohne `-var` läuft der Health-Check in 20 min Timeout, wenn VM aus ist.

## Updates

```bash
talosctl etcd snapshot db.snapshot                                    # vorher
talosctl upgrade --preserve --image "$(../../tools/tf output -raw installer_image)"
talosctl upgrade-k8s --to <kubernetes_version>
```

Cilium wird nicht mit `helm upgrade` aktualisiert, sondern über
`cilium_version` in [variables.tf](variables.tf) und ein `tf apply` — das
schreibt die Machine-Config neu, Talos rollt das Manifest nach. Renovate
schlägt die Chart-Version vor.

`--preserve` ist bei einem Single-Node-Cluster Pflicht. Das `installer_image`
enthält die richtige Schematic-ID — mit einem nackten
`ghcr.io/siderolabs/installer` gehen die System-Extensions verloren. Danach
`talos_version` bzw. `kubernetes_version` in [variables.tf](variables.tf)
nachziehen.

## Was hier bewusst fehlt

 Für später vorgesehen:

- **Ingress-Firewall mit `admin_sources`.** Der Node hängt offen im LAN, die
  Talos-API ist dort nur durch Client-Zertifikate geschützt. Das muss stehen,
  bevor die Fritzbox irgendetwas weiterleitet — der Ablauf steht in
  [../../k8s/INBETRIEBNAHME.md](../../k8s/INBETRIEBNAHME.md), Schritt 3.
- **Plattform-Stack** (cert-manager, Traefik, Kyverno, CrowdSec, Headlamp).
- **serverTLSBootstrap** fürs Kubelet. Braucht einen Genehmiger im Cluster;
  ohne ihn bleibt der CSR `Pending` und der Health-Check bricht ab.
- **Secure Boot und LUKS2**, dann mit den `secureboot`-Varianten der Image
  Factory und eigenen Keys.

## macvtap: wer wen erreicht

Ist auf dem Host Bridging abgeschaltet — `ip -br link` zeigt dann kein `br0` —,
hängt das Bein per macvtap direkt am physischen Interface. Das hat eine
Eigenart, die kein Fehler ist:

- Arbeitsstation und übriges LAN erreichen die VM — ✓
- Docker-Container in einem macvlan-Netz auf demselben Parent — ✓
- der Hypervisor selbst erreicht die VM **nur dann**, wenn er sich ein eigenes
  macvlan-Bein am selben Parent gibt — sonst nicht, und umgekehrt ebenso wenig

Der Grund ist derselbe, aus dem die dritte Zeile funktioniert: macvtap-
Geschwister im `bridge`-Modus am selben Parent dürfen untereinander sprechen.
Der Hypervisor spricht über das physische Interface und ist damit kein
Geschwister, sondern der Elternteil — und der ist ausgeschlossen. Ein eigenes
macvlan-Bein macht ihn zum Geschwister und hebt die Trennung auf.

### Auf diesem Host ist das bereits der Fall

Unraid legt bei eingeschaltetem *Host access to custom networks* genau so ein
Bein an. Nachgemessen, statt aus der Regel oben gefolgert:

```bash
ssh root@<host> ip -d link show vhost0
```

```
vhost0@bond0: <BROADCAST,MULTICAST,UP,LOWER_UP> ...
    macvtap mode bridge ...
```

Dasselbe `macvtap mode bridge` am selben Parent `bond0`, das auch das Bein der
VM zeigt. Beide Richtungen laufen entsprechend:

```bash
ssh root@<host> ping -c2 <node-ip>          # aus dem Hypervisor in die VM
kubectl run t --rm -i --restart=Never --image=busybox:1.36 \
  -- ping -c2 <host-ip>                      # aus einem Pod zum Hypervisor
```

Damit sind NFS-Exporte des Hypervisors aus dem Cluster erreichbar — der
Speicher in
[k8s/flux/clusters/talos-cp1/nfs-storage.yaml](../../k8s/flux/clusters/talos-cp1/nfs-storage.yaml)
steht auf genau diesem Befund.

Er ist allerdings geliehen: Er hängt an einer Unraid-Einstellung, die nichts
mit diesem Repo zu tun hat und die niemand hier bemerkt, wenn sie jemand
zurücknimmt. Das Fehlerbild wäre dann kein Fehler, sondern das Hängen aller
NFS-Mounts (`hard`, siehe die StorageClass dort). Wer die Abhängigkeit nicht
will, gibt der VM ein zweites Bein an einem libvirt-Netz und exportiert
dorthin.
