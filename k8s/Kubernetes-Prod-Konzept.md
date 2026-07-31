# Kubernetes für Test & Prod im Homelab – Konzept

Entscheidungsgrundlage für einen Test-/Prod-Kubernetes-Cluster auf dem Unraid-Homelab,
ergänzend zum bestehenden Minikube-Setup für lokale Entwicklung.

**Stand:** 2026-07-31

---

## 1. Ausgangslage

| Aspekt | Ist-Zustand |
|---|---|
| Hardware | Unraid-Homelab, **16 GB RAM** |
| Virtualisierung | KVM/libvirt, per Terraform verwaltet (`vm/alpine/main.tf`, `vm/ubuntu-desktop/main.tf`) |
| Dev-Cluster | Minikube auf Ubuntu, per Ansible (`ansible/minikube-install.yml`), CNI: Calico |
| Manifeste | Kustomize mit `base` + `overlays/minikube|prod` (`k8s/whoami/`) |
| Bestandsdienste | Docker Compose: Immich, Nextcloud, Paperless, Keycloak, Grafana/Prometheus/Loki, AdGuard, Navidrome, SFTPGo, Linkwarden, ntfy, Uptime-Kuma, Kopia |
| Edge | Traefik mit CrowdSec (`traefik/`) |
| Dependency-Updates | Renovate (`renovate.json5`) |

**Anforderungen an den neuen Cluster:**

- Läuft in einer VM auf Unraid, verwaltet über Terraform
- Trennung von Test und Prod
- Maximale Sicherheit – Teile der Prod-Dienste werden ins Internet exponiert

---

## 2. Distributions-Entscheidung

### Empfehlung: Talos Linux

Talos Linux ist ein minimales, immutables Betriebssystem, das ausschließlich dafür
gebaut ist, Kubernetes auszuführen.

**Warum es für "maximal sicher" die beste Wahl ist:**

- **Kein SSH, keine Shell, kein Paketmanager, kein systemd.** Die klassische
  Angriffsfläche einer Linux-VM entfällt fast vollständig. Bricht ein
  internetexponierter Pod aus, findet er kein Userland vor, in dem er sich
  einnisten könnte.
- **Read-only, immutable rootfs.** Kein Config-Drift, keine manuell verbogene
  Node, die niemand mehr nachvollziehen kann.
- **Verwaltung ausschließlich über eine gRPC-API mit mTLS** (`talosctl`),
  rollenbasiert. Kein Login-Prompt, den man vergessen kann zu härten.
- **CIS-Benchmark-konform ab Werk**, KSPP-gehärteter Kernel, optional Secure Boot
  und LUKS2-Disk-Encryption mit TPM-Bindung.
- **Nativer Terraform-Provider** (`siderolabs/talos`): PKI, Machine-Config und
  Bootstrap deklarativ. Zusammen mit dem bereits genutzten `dmacvicar/libvirt`-Provider
  steht der komplette Cluster in einem `terraform apply` – genau die Richtung, in
  die das Repo ohnehin geht.

**Der Preis:** Ansible ist auf den Nodes nicht mehr nutzbar (kein SSH).
Node-Konfiguration läuft komplett über Terraform bzw. Machine-Config. Für das
Terraform-first-Ziel ist das eher Feature als Verlust – das bestehende Ansible
bleibt für Minikube-Dev und die Unraid-Hosts relevant.

### Vergleich

| | **Talos** | RKE2 | k3s | kubeadm |
|---|---|---|---|---|
| Sicherheit ab Werk | sehr hoch | hoch (CIS default, FIPS) | mittel (Härtung manuell) | mittel |
| RAM-Baseline (1 Node) | ~2 GB | ~2,5–3 GB | ~1 GB | ~2 GB |
| Terraform-Integration | nativer Provider | nur VM + Ansible | nur VM + Ansible | manuell |
| Lernkurve | hoch (grundlegend anders) | mittel | niedrig | hoch |
| Debugging | nur `talosctl` | gewohnt | gewohnt | gewohnt |
| Immutable / A-B-Upgrades | ja | nein | nein | nein |

**Wann die Alternativen sinnvoll wären:**

- **RKE2** – wenn eine normale VM mit SSH und dem bestehenden Ansible-Workflow
  zwingend erhalten bleiben soll. Der sicherheitsstärkste "klassische" Weg.
- **k3s** – nur wenn RAM das absolut dominierende Kriterium ist. Härtung (CIS-Profil,
  Admission-Config, Flannel gegen Cilium tauschen) muss dann selbst nachgezogen werden.
- **kubeadm** – kein Vorteil gegenüber den obigen, mehr Handarbeit.

---

## 3. Der eigentliche Engpass: 16 GB RAM

Das ist die harte Einschränkung des Konzepts. Auf dem Unraid-Host laufen bereits
Immich, Nextcloud, Paperless, Keycloak und ein Grafana/Prometheus/Loki-Stack – das
ist der Löwenanteil der 16 GB. Realistisch bleiben für Kubernetes **6–8 GB**.

**Optionen:**

| Variante | RAM | Isolation | Bewertung |
|---|---|---|---|
| 2 VMs (Test + Prod) | Test 3 GB + Prod 5 GB | gut – getrennte Kernel | Sicherheitstechnisch richtig, aber ohne Reserve |
| 1 VM, Namespace-Trennung | ~5 GB | schwächer – gemeinsamer Kernel | Pragmatisch, Overlays sind schon vorbereitet |
| RAM-Upgrade auf 32–64 GB | – | – | **Empfohlen** |

Bei internetexponierter Prod sollten keine Test-Workloads auf demselben Kernel
laufen. DDR4 ist günstig verglichen mit dem Aufwand, den man sonst in
Isolations-Workarounds steckt.

**Wichtiger Hebel unabhängig davon:** Dienste schrittweise von Docker Compose nach
Kubernetes *migrieren* statt parallel zu betreiben. Dann verschiebt sich der
RAM-Bedarf, statt sich zu verdoppeln. Das `whoami`-Kustomize-Setup ist genau der
richtige Anfang dafür.

---

## 4. Absicherung der Internet-Exposition

- **Traefik + CrowdSec als Edge vor dem Cluster behalten**, aber vom Unraid-Host in
  eine eigene VM im DMZ-Segment ziehen. Die bestehende WAF-/Bouncer-Konfiguration
  bleibt erhalten, es gibt weiterhin nur einen TLS-Terminierungspunkt. Begründung,
  Zielbild und der Befund zur heutigen Netzanbindung in
  → [Edge-Architektur.md](Edge-Architektur.md).
- **Kubernetes-API niemals exponieren** – Zugriff ausschließlich über WireGuard
  oder Tailscale.
- **Cilium statt Calico** im Prod-Cluster: eBPF, saubere NetworkPolicy-Durchsetzung,
  Hubble für Sichtbarkeit. Talos ist explizit dafür ausgelegt.
- **Default-deny NetworkPolicies** in jedem Namespace (im `whoami`-Base bereits angelegt).
- **Pod Security Admission auf `restricted`** pro Namespace.
- **Kyverno** für Policies – deutlich leichter als OPA Gatekeeper.
- **Trivy Operator** für Image-Scans.
- **Flux statt ArgoCD** für GitOps – beim gegebenen RAM-Budget der bessere Kandidat,
  und es passt zum Repo-Layout.
- **Secrets** über SOPS/age im Git oder Sealed Secrets. Vault ist bei 16 GB zu schwer.
- **Backups**: `talosctl etcd snapshot` für den Cluster-State, Kopia für PV-Daten.

---

## 5. Edge-Architektur: Reverse Proxy und Exposition

> **Ausgelagert nach [Edge-Architektur.md](Edge-Architektur.md).**

Legt fest, wo der Reverse Proxy steht und wie die Kette vom Internet bis zum Pod
aussieht. Die getroffenen Entscheidungen in Kurzform:

- **Edge bleibt außerhalb des Clusters**, zieht aber vom Unraid-Host in eine eigene
  VM im DMZ-Segment – die heutige macvlan-Anbindung an `bond0` ist die größte
  strukturelle Schwachstelle.
- **Segmentierung über eine Firewall-VM** (Alpine + nftables) hinter der Fritzbox,
  die selbst keine DMZ bauen kann und auch nicht muss. Umgesetzt in
  → [../vm/firewall/](../vm/firewall/).
- **Traefik auf beiden Ebenen** – am Edge und als Cluster-Ingress; `ingress-nginx`
  scheidet wegen Retirement aus.
- **mTLS und Cilium-NetworkPolicy** zwischen Edge und Cluster verhindern, dass die
  Sicherheitsschicht umgangen wird.
- **Cloudflare Tunnel verworfen** – Klartext-Einsicht durch Dritte.

---

## 6. Update-Konzept

Zentraler Punkt: **Talos-OS und Kubernetes werden getrennt aktualisiert.** Das OS
kann angehoben werden, ohne Kubernetes anzufassen – und umgekehrt. Kein
`apt upgrade`, kein `unattended-upgrades`, kein Reboot-Required-Flag.

### 6.1 OS-Update (Talos selbst)

Talos hat zwei Boot-Partitionen (A/B). Ein Upgrade schreibt das neue Image auf die
inaktive Partition und bootet dorthin.

```bash
talosctl upgrade \
  --nodes 10.0.0.10 \
  --image ghcr.io/siderolabs/installer:v1.x.y \
  --preserve
```

Ablauf: Node wird cordoned und drained → Dienste stoppen → neues Image auf die
inaktive Partition → Reboot. Schlägt der Boot fehl, fällt Talos automatisch auf die
alte Partition zurück; manuell geht das mit `talosctl rollback`.

> **Achtung – zwei Fallstricke:**
>
> 1. **`--preserve` ist bei Single-Node-Clustern Pflicht.** Ohne das Flag wird die
>    EPHEMERAL-Partition gewischt und damit etcd. Bei Multi-Node-Clustern ist das
>    unkritisch (der Node holt sich den State zurück), bei einem einzelnen Node
>    bedeutet es Totalverlust.
> 2. **Bei System-Extensions** (z. B. `qemu-guest-agent` für libvirt, iSCSI-Tools)
>    muss das Upgrade-Image über die **Image Factory** mit *derselben Schematic-ID*
>    gebaut werden. Mit dem nackten `installer`-Image sind die Extensions nach dem
>    Reboot weg.

Ein Reboot dauert typischerweise 1–2 Minuten. Bei einem Single-Node-Cluster ist das
echte Downtime – ein weiteres Argument für getrennte Test-/Prod-VMs, damit jedes
Upgrade zuerst auf Test durchgespielt wird.

### 6.2 Kubernetes-Update

Komplett separat und ohne Node-Reboot:

```bash
talosctl --nodes 10.0.0.10 upgrade-k8s --to 1.3x.y
```

Aktualisiert kube-apiserver, controller-manager, scheduler, kubelet, kube-proxy und
die CoreDNS-Manifeste rollierend.

**Regeln:** keine Minor-Version überspringen; erst Talos aktualisieren, dann Kubernetes.

### 6.3 Config-Änderungen

Änderungen an der Machine-Config (Netzwerk, Extensions, Kernel-Args, Zertifikate)
laufen über `talosctl apply-config` bzw. über die Terraform-Ressource
`talos_machine_configuration_apply`. Modi:

| Modus | Verhalten |
|---|---|
| `no-reboot` | für Felder, die live änderbar sind |
| `reboot` | für alles andere |
| `staged` | beim nächsten Reboot anwenden |

Der Terraform-Provider deckt PKI, Machine-Config und Bootstrap ab. Die OS-Upgrades
selbst laufen üblicherweise **nicht** über Terraform, sondern über `talosctl` oder
den Upgrade-Controller. Terraform bleibt zuständig für "wie sieht der Cluster aus",
nicht für "welches Image läuft gerade".

### 6.4 Automatisierung

- **`system-upgrade-controller`** (Rancher) fährt Talos- und Kubernetes-Upgrades als
  `Plan`-CRD im Cluster – deklarativ, GitOps-tauglich, mit definierten Wartungsfenstern.
- **Renovate** trackt Talos- und Kubernetes-Version im Repo und öffnet bei jedem
  Release einen PR. Derselbe Mechanismus, der heute schon die Compose-Images aktuell hält.
- **Flux + Renovate** übernehmen die Anwendungs-Updates: neuer Image-Tag → PR →
  Merge → Flux rollt aus.

Ergebnis: Renovate macht PRs für OS, Kubernetes und Apps, es wird gemergt, und der
Cluster zieht nach. Wie diese Kette konkret aufgebaut wird – Prüfungen, Branch-Modell
und Promotion – steht in → [CI-CD-Konzept.md](CI-CD-Konzept.md).

### 6.5 Praktische Reihenfolge

Vor jedem Upgrade:

```bash
talosctl -n 10.0.0.10 etcd snapshot db.snapshot
```

Dann: Test-Cluster upgraden → beobachten → Prod-Cluster upgraden.

Talos-Minor-Releases erscheinen etwa alle zwei bis drei Monate – realistisch also
vier bis sechs Wartungsfenster im Jahr statt wöchentlicher Paket-Updates.

### 6.6 Was sich gegenüber heute ändert

Statt `apt upgrade` auf einer VM plus Docker-Image-Pulls gibt es ein atomares,
versioniertes Image mit automatischem Rollback.

Der Verlust: bei Problemen kann man sich nicht per SSH einloggen und nachsehen.
Diagnose läuft über `talosctl logs`, `talosctl dmesg`, `talosctl services`,
`talosctl health`. Das ist die Kehrseite der Härtung und der Hauptgrund, warum ein
Test-Cluster stehen sollte, bevor Prod darauf läuft.

---

## 7. CI/CD und Automatisierung

> **Ausgelagert nach [CI-CD-Konzept.md](CI-CD-Konzept.md).**

Wie sich der Kubernetes-Aufbau und die zugehörigen VMs nach einmaliger Einrichtung
selbst aktuell halten. Die getroffenen Entscheidungen in Kurzform:

- **Erst CI, dann mehr Automerge** – heute existiert keine einzige Prüfung, das ist
  die Voraussetzung für alles Weitere.
- **Branch-Modell mit Promotion**: Test-Cluster zieht `main`, Prod-Cluster zieht
  `prod`, dazwischen ein Fast-Forward-Merge nach Karenzzeit.
- **Beide Cluster ziehen über Flux** – keine Credentials für den libvirt-Host bei
  GitHub, `terraform plan` bleibt lokal.
- **Infrastruktur applyed nicht automatisch**: VM-Definitionen, Talos-Majors und
  Firewall-Regeln bleiben manuell.
- **Renovate bleibt der einzige Update-Mechanismus**, erweitert um den
  `kubernetes`-Manager und Talos-/Kubernetes-Quellen.

---

## 8. Vorgehen

1. **Talos-Test-VM** (2 vCPU / 3 GB) per Terraform aufsetzen, neben der bestehenden
   `vm/alpine`-Config – z. B. als `vm/talos-test/`.
2. **`whoami` über das bestehende Prod-Overlay** dorthin deployen, um den Weg zu validieren.
3. **Cilium + Flux + cert-manager** aufsetzen, Traefik als Cluster-Ingress
   (→ [Edge-Architektur](Edge-Architektur.md), Abschnitt 7), bestehenden Unraid-Traefik vorläufig als Edge davorhängen.
4. **Prod-VM bauen**, danach Dienste einzeln aus Docker Compose migrieren.
5. **Edge nach [Edge-Architektur.md](Edge-Architektur.md) umbauen** – Schritte 1 und 2
   der dortigen Umsetzungsreihenfolge (Abschnitt 9) können jederzeit vorgezogen
   werden, sie hängen nicht am Cluster.

---

## 9. Offene Punkte

- RAM-Upgrade des Unraid-Hosts entscheiden (bestimmt, ob ein oder zwei Cluster)
- Talos-VMs ins Segment `fw-cluster` umziehen: dort gibt es bewusst kein DHCP
  (der Hypervisor soll kein Bein in DMZ/Cluster haben). Die Node-IP muss dann aus
  der Machine-Config kommen statt wie in `vm/talos-test` aus einer
  DHCP-Reservierung – inklusive Hostname, der dort heute von dnsmasq stammt
- Reihenfolge der Dienst-Migration festlegen (Kandidaten mit wenig State zuerst)
- Secrets-Strategie festlegen: SOPS/age vs. Sealed Secrets
- Backup-Strategie für PVs: Kopia-Integration oder Velero
- Egress-Test aus der DMZ in die CI hängen ([Edge-Architektur](Edge-Architektur.md), Abschnitt 5) –
  das Skript steht (`vm/firewall/verify/egress-test.sh`), die Einbindung in die
  CI fehlt noch; sie ist Voraussetzung dafür, dass die Entscheidung gegen
  OPNsense trägt
- Portfreigaben ins Fritzbox-Gastnetz im Menü gegenprüfen ([Edge-Architektur](Edge-Architektur.md), Abschnitt 5) – die
  Architektur geht davon aus, dass es nicht geht
- IPv6-Strategie für DMZ- und Cluster-Segment festlegen ([Edge-Architektur](Edge-Architektur.md), Abschnitt 5)
- Erreichbarkeit von `192.168.178.5:8080` im LAN verifizieren ([Edge-Architektur](Edge-Architektur.md), Abschnitt 2)
- Dienst-Liste „öffentlich vs. nur VPN" verbindlich festlegen ([Edge-Architektur](Edge-Architektur.md), Abschnitt 3)
- Status von `ingress-nginx` gegenprüfen, bevor die Ingress-Entscheidung final wird
- `k8s/whoami/overlays/prod/ingress.yaml` von `nginx` auf Traefik umstellen
  (IngressClass, Middleware-Annotation, `whitelist-source-range` entfällt)
- Karenzzeit für die automatische Promotion festlegen ([CI-CD-Konzept](CI-CD-Konzept.md), Abschnitt 2)
- Bezugsquelle für die CRD-Schemas von `kubeconform` klären ([CI-CD-Konzept](CI-CD-Konzept.md), Abschnitt 3) – ohne sie
  scheitert die Prüfung an Cilium-, Traefik- und Flux-Ressourcen
