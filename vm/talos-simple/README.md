# Talos-Node auf Unraid

Ein Talos-Node mit Kubernetes, feste Adresse im Heimnetz, erreichbar von der
Arbeitsstation. Mehr nicht — und das ist der Punkt.

| | |
|---|---|
| VM | `talos-cp1` auf Unraid (`192.168.178.3`), 4 vCPU, 4 GB RAM, 100 GB Disk |
| Adresse | `192.168.178.230`, statisch — zugleich Kubernetes-API-Endpoint |
| Netz | macvtap auf `bond0` |
| Talos | v1.13.7, Image Factory mit `qemu-guest-agent` |
| Kubernetes | 1.36.3 |
| CNI | Talos-Default (Flannel) |
| Storage-Pool | `homelab` → `/mnt/cache/domains` |

## Voraussetzungen

- `tofu` und `talosctl` lokal, SSH als `root` auf den Unraid-Host
- VM-Manager auf Unraid aktiv. Den Storage-Pool bringt entweder `vm/edge` mit
  oder dieses Modul legt ihn selbst an — vorher gegenprüfen:

  ```bash
  virsh --connect qemu+ssh://root@192.168.178.3/system pool-list --all
  ```

  Leere Liste → `manage_pool = true` und `pool_path` in `terraform.tfvars`.
  Pool schon da → `manage_pool` auf `false` lassen.
- Genug freier Speicher auf dem Host. Maßgeblich ist `available`, nicht `free`:

  ```bash
  ssh root@192.168.178.3 free -m
  ```

  Unraid hat ab Werk keinen Swap. Bleibt `available` nach Abzug der 4 GB unter
  etwa 1,5 GB, erst einen Container abschalten.

## Cluster erstellen

Der State dieses Moduls liegt in Gitea, nicht im Verzeichnis — als einziges
Modul bisher. Die Zugangsdaten kommen aus der Umgebung, nicht aus dem
`backend`-Block; Token anlegen und Details in [../../gitea/README.md](../../gitea/README.md).

Einmalig einrichten, damit sie jede Shell hat statt nur die eine:

```bash
mkdir -p ~/.config/tofu && chmod 700 ~/.config/tofu
umask 077 && cat > ~/.config/tofu/gitea.env <<'EOF'
export TF_HTTP_USERNAME="nico"
export TF_HTTP_PASSWORD="<Gitea-Token mit write:package>"
EOF
chmod 600 ~/.config/tofu/gitea.env

echo '[ -f ~/.config/tofu/gitea.env ] && . ~/.config/tofu/gitea.env' >> ~/.bashrc
```

Danach in einer neuen Shell:

```bash
cd vm/talos-simple
cp terraform.tfvars.example terraform.tfvars   # Werte prüfen
tofu init
tofu apply
```

Warum eine eigene Datei und nicht direkt `~/.bashrc`: die ist `644`, also für
jedes Konto auf dem Rechner lesbar. Die `600` hier schützt den Token allein
über die Dateirechte — verschlüsselt ist er nicht.

Zwei Fallen:

- `~/.bashrc` gilt nur für interaktive Shells. Cron, systemd-Units und
  `ssh host 'tofu ...'` sehen die Variablen nicht und brauchen die Datei
  explizit gesourct.
- Wer den Token stattdessen von Hand exportiert, tippt das `export` mit
  führendem Leerzeichen — dann hält `HISTCONTROL` ihn aus `~/.bash_history`
  heraus, sonst steht er dort im Klartext.

Meldet `tofu` trotz gesetzter Variablen `requires auth`, liegt es am
Token-Scope, nicht an der Umgebung:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -u "$TF_HTTP_USERNAME:$TF_HTTP_PASSWORD" \
  https://git.local.nico-steinmueller.de/api/packages/nico/terraform/state/vm-talos-simple
```

Der State liegt in Gitea unverschlüsselt, und darin stehen die
`talos_machine_secrets` — die CA, mit der sich beliebige Admin-Zertifikate für
Talos und Kubernetes ausstellen lassen. Wer Zugriff auf das appdata-Verzeichnis
oder ein Backup des Unraid-Hosts hat, hat damit den Cluster. Für den Zielzustand
gehört hier `terraform { encryption { … } }` dazu.

Ein `apply` sperrt den State für seine Laufzeit; ein zweiter Aufruf von einem
anderen Gerät bricht mit einer Lock-Meldung ab, statt danebenzuschreiben. Bleibt
nach einem Abbruch eine Sperre stehen, hebt `tofu force-unlock <ID>` sie auf —
die ID steht in der Fehlermeldung.

`apply` kehrt erst zurück, wenn der Cluster wirklich gesund ist — die Data
Source `talos_cluster_health` blockiert so lange. Ein grünes `apply` heißt also:
Control Plane läuft, etcd ist initialisiert, der Node ist `Ready`. Rechne mit
10–20 Minuten, der größte Teil davon ISO-Download und zwei Reboots.

Was dabei passiert:

1. Image Factory liefert ISO- und Installer-URL zur Schematic-ID
2. libvirt lädt die ISO in den Pool `homelab`, legt Disk und VM an
3. VM bootet von ISO in den **Maintenance-Mode** — durch den `ip=`-Kernel-Parameter
   bereits unter `192.168.178.230`
4. Terraform schiebt die Machine-Config rein → Talos installiert sich auf
   `/dev/vda` und rebootet von Disk
5. `talos_machine_bootstrap` initialisiert etcd
6. Health-Check wartet auf einen gesunden Cluster

`kubeconfig` und `talosconfig` schreibt Terraform direkt ins Verzeichnis, beide
mit `0600` und in `.gitignore`.

## Zugang

```bash
cd vm/talos-simple
export TALOSCONFIG=$PWD/talosconfig
export KUBECONFIG=$PWD/kubeconfig

talosctl health
kubectl get nodes -o wide
```

## Diagnose ohne SSH

Das ist der Teil, der sich gegenüber einer normalen VM am stärksten ändert — es
gibt keine Shell auf dem Node.

```bash
talosctl dmesg                      # Kernel- und Boot-Logs
talosctl logs kubelet               # Logs einzelner Talos-Dienste
talosctl services                   # Status aller Talos-Dienste
talosctl health --wait-timeout 10m  # vollständiger Health-Check
```

Kommt der Node gar nicht erst hoch und ist die API deshalb nicht erreichbar,
bleibt die serielle Konsole — Talos schreibt Boot und Installation vollständig
dorthin:

```bash
virsh -c qemu+ssh://root@192.168.178.3/system console talos-cp1
```

## Aufräumen

```bash
tofu destroy -var wait_for_health=false
```

Das `-var` ist kein Beiwerk: Data Sources werden vor jedem Plan gelesen, auch
beim Zerstören. Ist die VM schon aus, läuft der Health-Check sonst erst in
seinen 20-Minuten-Timeout, bevor überhaupt ein Plan entsteht. Dasselbe Flag
hilft bei Reparaturläufen, wenn der Check genau das `apply` blockiert, das den
Fehler beheben würde.

## Updates

```bash
talosctl etcd snapshot db.snapshot                                    # vorher
talosctl upgrade --preserve --image "$(tofu output -raw installer_image)"
talosctl upgrade-k8s --to 1.36.3
```

`--preserve` ist bei einem Single-Node-Cluster Pflicht. Das `installer_image`
enthält bereits die richtige Schematic-ID — mit einem nackten
`ghcr.io/siderolabs/installer` gehen die System-Extensions verloren. Nach dem
Upgrade `talos_version` bzw. `kubernetes_version` in [variables.tf](variables.tf)
nachziehen.

## Was hier bewusst fehlt

Der Vorgänger in [../talos/](../talos/) konnte mehr und war deshalb nicht mehr
zu überblicken. Weggelassen und für später vorgesehen:

- **Cilium** — hier läuft der Talos-Default Flannel. Der Node ist damit ohne
  zweiten Schritt `Ready`.
- **DMZ-Bein zur Edge-VM**, Ingress-Firewall, `admin_sources`. Der Node hängt
  offen im Heimnetz; von außen erreichbar ist er nicht, weil die Fritzbox
  nichts hierher weiterleitet.
- **Plattform-Stack** (cert-manager, Traefik, Kyverno, CrowdSec, Headlamp) aus
  `k8s/platform`. Der brauchte allein 1900 MiB Requests — der Grund, warum 4 GB
  hier reichen und dort nicht.
- **serverTLSBootstrap** für das Kubelet. Braucht einen Genehmiger im Cluster;
  ohne ihn bleibt der CSR `Pending` und der Health-Check bricht ab.
- **Secure Boot und LUKS2.** Bleiben das Ziel, dann aber mit den
  `secureboot`-Varianten aus der Image Factory und eigenen Keys.

## Was nicht weg darf

Diese Punkte sehen nach Detail aus, sind aber jeweils die Ursache eines
fehlgeschlagenen `apply` gewesen. Ausführlich kommentiert an Ort und Stelle:

- **q35 mit UEFI, Secure Boot aus.** q35 hängt alle Geräte hinter
  PCIe-Root-Ports, die SeaBIOS nicht enumeriert — der Gast sähe kein einziges
  virtio-Gerät, weder NIC noch Disk. Und mit Secure Boot wählt libvirt das
  OVMF-Image mit den Microsoft-Keys, gegen das die Talos-ISO nicht signiert ist.
  `features.acpi = true` ist für UEFI Pflicht.
- **`efi_loader`/`efi_vars_template`.** Auf Unraid zwingend: Der mitgelieferte
  libvirt-Deskriptor nennt eine NVRAM-Vorlage, die das Paket nicht enthält.
- **`ip=`-Kernel-Parameter in der Schematic.** Ohne ihn hat der Node im
  Maintenance-Mode eine DHCP-Adresse, und der Config-Apply zielt auf die
  statische — er läuft in seinen Timeout, während die VM als „gestartet" gilt.
- **Schematic-ID im ISO-Dateinamen** plus `replace_triggered_by`. Sonst tauscht
  der Provider die Datei aus, das Domain-XML bleibt gleich, und die VM läuft auf
  dem alten, bereits gelöschten Inode weiter.
- **`cache = "none"`, `io = "native"`.** Sonst hält der Host jeden Block der VM
  ein zweites Mal im Page-Cache — auf 16 GB ohne Swap der Auslöser für
  dauerhaftes `kswapd0` und 70 % iowait.
- **Discovery aus, beide Registries einzeln.** Der `kubernetes`-Registry ist mit
  Kubernetes 1.32+ nicht kompatibel und erzeugt eine Endlosschleife aus
  `nodes is forbidden`; der `service`-Registry meldet Metadaten an
  `discovery.talos.dev`. Das globale `enabled: false` allein reicht nicht, und
  die Änderung greift erst nach einem Reboot.
- **`patches/hostname.yaml` nach `patches/node.yaml.tftpl`.** Talos legt selbst
  ein `HostnameConfig`-Dokument an, das mit `machine.network.hostname`
  kollidiert; überschreiben hilft nicht, es muss gelöscht werden.

## macvtap: wer wen erreicht

Auf diesem Host ist Bridging abgeschaltet — `ip -br link` zeigt `bond0` und
`vhost0`, aber kein `br0`. Das Bein hängt deshalb per macvtap direkt am
physischen Interface, und das hat eine Eigenart, die kein Fehler ist:

- Arbeitsstation und übriges LAN erreichen die VM — ✓
- Docker-Container in einem macvlan-Netz auf demselben Parent erreichen sie — ✓
- **der Unraid-Host selbst erreicht die VM nicht**, und umgekehrt ebenso wenig

`ping 192.168.178.230` aus einer SSH-Sitzung auf Unraid läuft also ins Leere,
obwohl alles in Ordnung ist. Für NFS-Exporte desselben Hosts heißt das: über
dieses Bein nicht erreichbar.
