# Talos-Test-Cluster

Single-Node-Kubernetes auf Talos Linux, vollständig über Terraform erzeugt –
Schritt 1 aus [../../k8s/Kubernetes-Prod-Konzept.md](../../k8s/Kubernetes-Prod-Konzept.md).

Läuft aktuell lokal auf `qemu:///system`. Für den späteren Umzug auf Unraid
muss nur `libvirt_uri` und ggf. `libvirt_pool` angepasst werden – die
Cluster-Definition bleibt identisch.

## Was hier entsteht

| Ressource | Wert |
|---|---|
| libvirt-Netz | `talos-test`, NAT, `192.168.150.0/24`, Bridge `virbr-talos` |
| VM | `talos-test-cp1`, 2 vCPU, 3 GB RAM, 20 GB Disk |
| Node-IP | `192.168.150.10` (DHCP-Reservierung auf feste MAC) |
| Talos | v1.13.7, Image Factory mit `qemu-guest-agent` |
| Kubernetes | 1.36.3 – identisch zu `ansible/minikube-install.yml` |
| CNI | Talos-Default (Flannel) – Cilium folgt in Schritt 3 |

## Voraussetzungen

- `terraform`, `libvirt`/`qemu-kvm`, Benutzer in der Gruppe `libvirt`
- `talosctl` für den Tagesbetrieb:

  ```bash
  curl -sL https://talos.dev/install | sh
  ```

## Cluster erstellen

```bash
cd vm/talos-test
terraform init
terraform apply
```

`terraform apply` ist bewusst so gebaut, dass es erst zurückkehrt, wenn der
Cluster wirklich gesund ist – die Data Source `talos_cluster_health` blockiert
so lange. Ein grünes `apply` bedeutet also: Control Plane läuft, etcd ist
initialisiert, der Node ist `Ready`.

Ablauf im Hintergrund:

1. Image Factory liefert ISO- und Installer-URL zur Schematic-ID
2. libvirt lädt die ISO in den Pool, legt Netz, Disk und VM an
3. VM bootet von ISO in den **Maintenance-Mode** (noch keine Config, DHCP-IP =
   reservierte IP)
4. `talos_machine_configuration_apply` schiebt die Machine-Config rein → Talos
   installiert sich auf `/dev/vda` und rebootet von Disk
5. `talos_machine_bootstrap` initialisiert etcd
6. Health-Check wartet auf einen gesunden Cluster

## Zugang einrichten

```bash
terraform output -raw talosconfig > talosconfig
terraform output -raw kubeconfig  > kubeconfig

export TALOSCONFIG=$PWD/talosconfig
export KUBECONFIG=$PWD/kubeconfig

talosctl health
kubectl get nodes -o wide
```

Beide Dateien enthalten Client-Zertifikate mit vollem Cluster-Zugriff und sind
über die lokale `.gitignore` ausgeschlossen.

## Diagnose ohne SSH

Das ist der Teil, der sich gegenüber einer normalen VM am stärksten ändert –
es gibt keine Shell auf dem Node.

```bash
talosctl dmesg                      # Kernel- und Boot-Logs
talosctl logs kubelet               # Logs einzelner Talos-Dienste
talosctl services                   # Status aller Talos-Dienste
talosctl get members                # Cluster-Mitglieder
talosctl health --wait-timeout 10m  # vollständiger Health-Check
```

Wenn der Node gar nicht erst hochkommt und die API deshalb nicht erreichbar
ist, bleibt die serielle Konsole:

```bash
virsh -c qemu:///system console talos-test-cp1
```

Talos schreibt den kompletten Boot- und Installationsvorgang dorthin.

## Migration testen

Der `whoami`-Dienst liegt bereits als Kustomize-Overlay vor:

```bash
kubectl apply -k ../../k8s/whoami/overlays/prod
```

Für das Prod-Overlay wird ein Ingress-Controller benötigt – kommt in Schritt 3
zusammen mit Cilium, Flux und cert-manager.

## Updates

Siehe [../../k8s/Kubernetes-Prod-Konzept.md](../../k8s/Kubernetes-Prod-Konzept.md), Abschnitt 5. Kurzfassung:

```bash
# etcd-Snapshot vorher
talosctl etcd snapshot db.snapshot

# OS-Upgrade - --preserve ist bei einem Single-Node-Cluster Pflicht
talosctl upgrade --preserve --image "$(terraform output -raw installer_image)"

# Kubernetes separat
talosctl upgrade-k8s --to 1.36.3
```

Das `installer_image`-Output enthält bereits die richtige Schematic-ID. Wird
stattdessen ein nacktes `ghcr.io/siderolabs/installer`-Image verwendet, gehen
die System-Extensions beim Upgrade verloren.

Nach einem Upgrade `talos_version` bzw. `kubernetes_version` in
[variables.tf](variables.tf) nachziehen, damit Terraform-State und
tatsächlicher Zustand nicht auseinanderlaufen.

## Aufräumen

```bash
terraform destroy
```

Entfernt VM, Disk, ISO und Netz vollständig.

## Bewusste Entscheidungen

**Eigenes libvirt-Netz statt `default`.** Das `default`-Netz hat einen
DHCP-Bereich über das gesamte `/24`, dort lässt sich keine kollisionsfreie
Reservierung anlegen. Terraform muss die Node-IP aber schon kennen, bevor die
VM existiert – der Maintenance-Mode ist nur unter einer bekannten Adresse
erreichbar. Deshalb ein eigenes Netz mit engem Dynamikbereich
(`.100`–`.199`) und fester Reservierung auf `.10`.

**Image Factory statt GitHub-Release-ISO.** Erzeugt ISO und Installer-Image aus
derselben Schematic-ID und hält sie im State. Damit ist der Fallstrick aus dem
Konzept – Extensions verschwinden beim Upgrade – strukturell ausgeschlossen.

**q35 mit UEFI, Secure Boot aus.** Beides ist nötig und war die Ursache des
ersten fehlgeschlagenen `apply`:

- **q35 braucht UEFI.** Die Maschinen-Variante hängt alle Geräte hinter
  PCIe-Root-Ports. Mit SeaBIOS werden die nicht enumeriert – der Gast sieht
  dann *kein einziges* virtio-Gerät, weder NIC noch Disk. Talos bootet zwar
  von der SATA-CD in den Maintenance-Mode, bleibt aber ohne Netzwerk, und
  `talos_machine_configuration_apply` läuft in `no route to host`.
- **Secure Boot muss explizit aus.** Sonst wählt libvirt automatisch das
  OVMF-Image mit einbetonierten Microsoft-Keys, und die Talos-ISO wird mit
  `Access Denied -- rejected probably by Secure Boot` abgelehnt.
- **`features.acpi = true`** ist Pflicht, sonst verweigert libvirt UEFI
  überhaupt.

Für den Prod-Cluster bleiben Secure Boot und LUKS2-Disk-Encryption das Ziel –
dann aber mit den signierten Varianten aus der Image Factory
(`urls.iso_secureboot`, `urls.installer_secureboot`) und eigenen Keys statt
mit den Microsoft-Defaults.

**Cluster-Discovery ist komplett abgeschaltet.** Der `kubernetes`-Registry ist
laut Talos-Doku deprecated und *"not compatible with Kubernetes 1.32+"*
([siderolabs/talos#9980](https://github.com/siderolabs/talos/issues/9980)) – der
`KubernetesPullController` listet Nodes mit der Kubelet-Identität
`system:node:<name>`, was der Node-Authorizer per Design verbietet. Mit den
Talos-Defaults produziert das auf Kubernetes 1.36 eine Endlosschleife aus
`nodes is forbidden`-Warnungen. Der `service`-Registry wiederum meldet
Cluster-Metadaten an `discovery.talos.dev`. Deshalb beides aus – siehe
[patches/hardening.yaml](patches/hardening.yaml).

Zwei Dinge dabei beachten: Das globale `enabled: false` allein reicht nicht,
die Registries müssen einzeln deaktiviert werden. Und die Änderung greift
**erst nach einem Reboot** (`talosctl reboot --wait`); die Config ist zwar
sofort live, der laufende Controller wird aber nicht beendet.

**Hostname kommt aus der DHCP-Reservierung, nicht aus der Machine-Config.**
dnsmasq liefert `talos-test-cp1` mit; wird der Name zusätzlich unter
`machine.network.hostname` gesetzt, lehnt Talos die Config mit
`static hostname is already set in v1alpha1 config` ab.

**Terraform-State enthält die Cluster-PKI.** `talos_machine_secrets` erzeugt
etcd-, Kubernetes- und Talos-CAs samt privater Schlüssel; die liegen im State.
`**/terraform.tfstate` ist in der Repo-`.gitignore` ausgeschlossen. Für Prod
sollte der State verschlüsselt abgelegt werden.
