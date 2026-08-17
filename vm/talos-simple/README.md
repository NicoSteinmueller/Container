# Talos-Node

Ein Talos-Node mit Kubernetes, feste Adresse im LAN, erreichbar von der
Arbeitsstation.

Konkrete Werte — Host, Adressen, Interface, Pool — stehen in
`$HOMELAB_VALUES/vm/talos-simple/terraform.tfvars`; hier nur Platzhalter

| | |
|---|---|
| VM | `<cluster_name>-cp1`, q35 mit UEFI, Dimensionierung aus den tfvars |
| Adresse | `<node-ip>`, statisch — zugleich Kubernetes-API-Endpoint |
| Netz | macvtap auf `lan_macvtap_dev` |
| Image | Image Factory, Talos + `qemu-guest-agent` |
| CNI | Talos-Default (Flannel) |

Versionen und Größen sind in [variables.tf](variables.tf) gepinnt, damit ein
Neuaufbau dieselbe Version ergibt wie der laufende Cluster.

## Voraussetzungen

- `tofu` und `talosctl` lokal, SSH als `root` auf den Host
- VM-Manager aktiv, Storage-Pool geklärt:

  ```bash
  virsh --connect qemu+ssh://root@<host>/system pool-list --all
  ```

  Leere Liste → `manage_pool = true` und `pool_path` setzen. Pool schon da → `manage_pool = false`.
- Genug Speicher: `ssh root@<host> free -m`. Maßgeblich ist `available`, nicht `free`;

## Cluster erstellen

State **und** Werte liegen in Gitea

```bash
cd vm/talos-simple
git -C "$HOMELAB_VALUES" pull
tf init
tf apply
```

`apply` kehrt erst zurück, wenn der Cluster gesund ist — `talos_cluster_health`
blockiert so lange. 10–20 Minuten, überwiegend ISO-Download und zwei Reboots:

1. Image Factory liefert ISO- und Installer-URL zur Schematic-ID
2. libvirt lädt die ISO in den Pool, legt Disk und VM an
3. VM bootet in den **Maintenance-Mode**, per `ip=`-Kernel-Parameter bereits
   unter `lan_ip`
4. Machine-Config rein → Talos installiert auf `install_disk`, rebootet
5. `talos_machine_bootstrap` initialisiert etcd
6. Health-Check wartet auf einen gesunden Cluster

`kubeconfig` und `talosconfig` landen im Verzeichnis, beide in `.gitignore`.

## Zugang

```bash
cd vm/talos-simple
export TALOSCONFIG=$PWD/talosconfig
export KUBECONFIG=$PWD/kubeconfig

talosctl health
kubectl get nodes -o wide
```

## Diagnose ohne SSH

Es gibt keine Shell auf dem Node.

```bash
talosctl dmesg                      # Kernel- und Boot-Logs
talosctl logs kubelet               # Logs einzelner Talos-Dienste
talosctl services                   # Status aller Talos-Dienste
talosctl health --wait-timeout 10m
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

`--preserve` ist bei einem Single-Node-Cluster Pflicht. Das `installer_image`
enthält die richtige Schematic-ID — mit einem nackten
`ghcr.io/siderolabs/installer` gehen die System-Extensions verloren. Danach
`talos_version` bzw. `kubernetes_version` in [variables.tf](variables.tf)
nachziehen.

## Was hier bewusst fehlt

 Für später vorgesehen:

- **Cilium** — hier läuft Flannel, damit ist der Node ohne zweiten Schritt
  `Ready`.
- **DMZ-Bein zur Edge-VM**, Ingress-Firewall, `admin_sources`. Der Node hängt
  offen im LAN; von außen erreichbar ist er nur, wenn der Router weiterleitet.
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
- **der Host selbst erreicht die VM nicht**, und umgekehrt ebenso wenig

`ping <node-ip>` aus einer SSH-Sitzung auf Host läuft also ins Leere, obwohl
alles in Ordnung ist. NFS-Exporte desselben Hosts sind über dieses Bein nicht
erreichbar.
