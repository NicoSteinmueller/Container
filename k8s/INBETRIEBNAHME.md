# Inbetriebnahme auf Unraid

Der Weg von einem leeren Unraid-Host zu Immich und Nextcloud im Internet.

## Zielbild

Ein Node, zwei LoadBalancer-Adressen aus dem LAN, vergeben von Cilium per
LB-IPAM und im Netz angekündigt per L2-Announcement. Kein `hostPort`, kein
`hostNetwork`, kein Sysctl.

| Adresse | Wer lauscht | Erreichbar von |
|---|---|---|
| `192.168.178.230` | Node selbst: Talos-API, Kubelet, kube-apiserver | nur `admin_sources`, siehe Schritt 3 |
| `192.168.178.231` | `ingress-internal` — Headlamp, whoami, Paperless | nur LAN |
| `192.168.178.232` | `ingress-public` — ntfy, später Immich, Nextcloud | Internet (Fritzbox-Freigabe) **und** LAN über Split-DNS |

Beide LoadBalancer-Adressen müssen außerhalb des Fritzbox-DHCP-Bereichs liegen
und dürfen nicht mit `lan_ip` aus [../vm/talos](../vm/talos) kollidieren.

## Voraussetzungen

| Punkt | Prüfen mit |
|---|---|
| VM-Manager aktiv (Settings → VM Manager → Enable VMs: Yes) | `ssh root@unraid virsh list --all` |
| Anbindung ans LAN: Bridge `br0` **oder** macvtap auf `bond0`/`ethX` | `ssh root@unraid ip -br link` |
| Platz für `vm_disk_gib` + `vm_data_disk_gib` | `ssh root@unraid df -h /mnt/nvme/domains` |
| RAM, siehe unten — Container zählen mit | `ssh root@unraid free -m` |

Share `domains` darf nur auf einem Pool liegen, sonst kann der Mover die Disk aufs Array schieben.

`terraform destroy` meldet den Pool nur ab (`destroy.delete = false`); das
Verzeichnis und alles darin bleiben unangetastet.

`tofu`, `talosctl`, `age` und `sops` kommen aus dem Tools-Playbook

## Anwendungen

Kein Dienst bekommt ein Ingress-Objekt, weder intern noch öffentlich

- Router und Service in `DynamicConfig.yaml` des Controllers
  ([intern](flux/network/ingress-internal/DynamicConfig.yaml),
  [öffentlich](flux/network/ingress-public/DynamicConfig.yaml)),
- ein `toEndpoints`-Block in `<controller>-egress` (`NetworkPolicies.yaml`),
- eine NetworkPolicy im Namespace des Dienstes, die den Controller hereinlässt
  — sonst greift sein eigenes Default-Deny.

**Jeder Dienst kommt zuerst über `ingress-internal` hoch**, auch die beiden,
die später öffentlich werden. Erst wenn er dort steht und die Daten stimmen,
ist Schritt 8 überhaupt sinnvoll.

**Pro migriertem Dienst, in dieser Reihenfolge:**

1. **Namespace** in [flux/core/namespaces/](flux/core/namespaces/Restricted.yaml)
   anlegen, mit `homelab.io/zone: internal`. Die Manifeste des Dienstes unter
   `flux/apps/<dienst>/`; die Gruppe `apps` wartet auf `platform`, `storage`
   und `homelab-secrets` ([flux/sync/Apps.yaml](flux/sync/Apps.yaml)).
2. **Speicher je Zugriffsmuster** ([flux/storage/](flux/storage/README.md)):
   Datenbanken, Indizes, Queues auf `local-path`, Bestände auf `nfs-unraid`.
   Nur NFS wird gesichert (Kopia, `/data/k8s`) - was auf `local-path` liegt
   und kein Dump ist, geht mit der VM verloren.
3. **Postgres** aus [templates/CnpgDatabase.yaml](templates/CnpgDatabase.yaml),
   dazu der `toEndpoints`-Block in `cnpg-egress`
   ([flux/platform/cloudnative-pg/](flux/platform/cloudnative-pg/README.md)).
   Secrets aus `homelab-secrets` brauchen den Namespace in der Liste von
   [Reloader](flux/platform/reloader/README.md).
4. **Route** über `ingress-internal`, die drei Handgriffe oben. Namen unter
   `*.k8s.nico-steinmueller.de` lösen im LAN schon auf `.231` auf.
5. **Daten übernehmen:** die Datenbank per Dump und Restore-Job
   ([Migration aus Docker](flux/platform/cloudnative-pg/README.md)), Dateien
   in das Verzeichnis des PVC unter `/mnt/user/k8s/<namespace>/<pvc>`. Vorher
   die Anwendung auf dem Host stoppen, sonst fehlt, was danach geschrieben
   wird.
6. **Prüfen**, dann bleibt der gestoppte Docker-Stack liegen: Er ist der
   Rückweg. Löschen erst, wenn der Dienst im Cluster ein paar Tage steht und
   ein Dump samt Kopia-Snapshot existiert.

## CrowdSec im Cluster

**Noch nicht dabei:** der AppSec-Listener. Er gehört vor die Portfreigabe
für Immich oder Nextcloud — an ntfy gibt es wenig, was eine WAF-Regel finden
könnte, und eine Middleware, die nie auslöst, ist eine, deren Ausfall niemand
bemerkt. Dazu gehören dann `crowdsecurity/appsec-virtual-patching`,
`appsec-crs` und die Nextcloud-Exclusion für `/remote.php/*`.

### Übergang, solange Dienste auf beiden Seiten laufen

Eine öffentliche Adresse, ein Port 443 — und dahinter zwei Proxies..

**Nur mit PROXY-Protocol.** Ohne es sieht `ingress-public` jede Verbindung
von Docker Proxy.

## Was danach noch fehlt

- **Die Portfreigabe** samt Übergang (Schritt 11) und AppSec (Schritt 10).
- **DNS-Aussetzer.** Talos meldet vereinzelt Timeouts gegen den einzigen
  Resolver `192.168.178.4` (AdGuard), gehäuft zur vollen Stunde:
  `talosctl -n 192.168.178.230 dmesg | grep dns-resolve-cache`.
