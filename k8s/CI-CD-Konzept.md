# CI/CD und Automatisierung

Teil des [Kubernetes-Prod-Konzepts](Kubernetes-Prod-Konzept.md), ausgelagert aus
dessen Kapitel 7.

**Stand:** 2026-07-31

> **Verweise:** „Kapitel N" bezieht sich auf das
> [Hauptkonzept](Kubernetes-Prod-Konzept.md), „Abschnitt N" auf dieses Dokument.

Ziel: Nach einmaliger Einrichtung hält sich das Setup weitgehend selbst aktuell.
Dieses Dokument gilt **ausschließlich für den Kubernetes-Aufbau und die zugehörigen
VMs** – der bestehende Docker-Compose-Betrieb auf Unraid bleibt davon unberührt.

**Ausgangslage:** Renovate läuft ausgereift (Digest-Pinning, Gruppierung, gestaffelte
Automerge-Regeln). In `.github/` liegt aber nur `CODEOWNERS` – es existiert **keine
einzige CI-Prüfung**. Damit fehlt genau die Voraussetzung dafür, Automerge
auszuweiten: erst das Netz spannen, dann loslassen.

---

## 1. Scope und Auslieferungswege

| Schicht | Artefakte | Wer rollt aus |
|---|---|---|
| VMs | `vm/talos-test/`, später `vm/talos-prod/`, Firewall-VM, Edge-VM | Terraform, **manuell** |
| Cluster-Plattform | Cilium, Flux, cert-manager, Traefik-Ingress, Kyverno | Flux, automatisch |
| Workloads | `k8s/*/base` + `overlays/` | Flux, automatisch |
| Versionen | Talos, Kubernetes | system-upgrade-controller (Kapitel 6.4) |

Infrastruktur soll **nicht** automatisch applyen. Ein Terraform-Apply, das eine VM
neu baut, oder ein Firewall-Regelsatz, der sich selbst ausrollt, gehören nicht in
einen nächtlichen Job. CI zeigt den Plan im PR, den Knopf drückt ein Mensch.

## 2. Der Test-Cluster als Promotion-Gate

Linting fängt Syntax. Ob ein Manifest wirklich deployt, sieht nur ein Cluster. Und
GitHub erreicht den libvirt-Host nicht – Credentials dorthin sollen dort auch nicht
liegen. Beides löst ein Branch-Modell, bei dem beide Cluster **ziehen**, statt dass
jemand pusht:

```
Renovate-PR  →  main  ──────────────►  Test-Cluster (Flux: branch main)
                  │                          │
                  │                     beobachten
                  │                          ▼
                  └── ff-merge ───►  prod  ──►  Prod-Cluster (Flux: branch prod)
```

Zwei `GitRepository`-Objekte auf dasselbe Repo mit unterschiedlichem `ref.branch`.
Damit wird die Regel aus Kapitel 6.5 – „Test zuerst, dann Prod" – strukturell
durchgesetzt statt nur dokumentiert.

**Promotion.** Ein Scheduled Workflow prüft täglich: CI auf `main` grün, Commit
älter als die festgelegte Karenzzeit, keine offenen Uptime-Kuma-Alerts → dann
`git merge --ff-only main` nach `prod`. Alles läuft allein durch, mit einem Fenster
zum Eingreifen. Der Workflow darf ausschließlich diesen Merge ausführen und braucht
keinen Zugriff auf irgendeine Maschine.

Solange dem Ablauf noch nicht zu trauen ist, bleibt die Promotion ein manueller
Fast-Forward-Merge – dieselbe Mechanik, nur mit Mensch.

## 3. CI-Prüfungen

**Manifeste:**

- `kustomize build` für jedes Overlay
- `kubeconform` – mit `-schema-location` für die CRDs von Cilium, Traefik und Flux,
  sonst scheitert es an den eigenen Ressourcen
- `kube-linter` oder Kyverno-CLI gegen die eigenen Policies: PSA `restricted`,
  gesetzte Resource-Limits, kein `:latest`, `runAsNonRoot`

**VMs:**

- `talosctl validate --mode metal` gegen `vm/talos-test/patches/` – prüft
  `hardening.yaml` und `single-node.yaml` gegen das Machine-Config-Schema, bevor eine
  VM daran scheitert
- `terraform fmt -check`, `terraform validate`, `tflint`
- `ansible-lint` für die Playbooks der Firewall- und Edge-VM
- nftables-Egress-Test aus [Edge-Architektur](Edge-Architektur.md), Abschnitt 5 gegen die Test-Umgebung

> **`terraform plan` bleibt lokal.** Es bräuchte Zugriff auf libvirt und den State –
> also Unraid-Credentials bei GitHub. `validate` und `tflint` laufen ohne
> Zugangsdaten und fangen den Großteil der Fehler.

## 4. Renovate erweitern

Die bestehende Konfiguration deckt Compose und Dockerfiles ab. Für diesen Scope
fehlen:

| Quelle | Manager |
|---|---|
| Talos-Version, Installer-Image | custom regex (analog zum `minikube`-Muster) |
| Kubernetes-Version für `upgrade-k8s` | custom regex |
| Provider `siderolabs/talos`, `dmacvicar/libvirt` | `terraform` (Default aktiv) |
| Cilium, cert-manager, Kyverno, Trivy-Operator | `helmv3` / `flux` |
| Images in `k8s/**` | **`kubernetes`** |
| Alpine-Release für Firewall- und Edge-VM | custom regex in Terraform |

> **Konkrete Lücke:** Der `kubernetes`-Manager hat **keine Default-Dateimuster**.
> Ohne explizite `managerFilePatterns` für `k8s/**` sieht Renovate die Manifeste
> schlicht nicht.

**Flux Image Automation wird nicht eingesetzt.** Es könnte Image-Tags direkt in Git
schreiben, deckt aber nur Images ab. Renovate erfasst zusätzlich Terraform, Talos,
Helm und Alpine, liefert Changelogs und ist im Repo eingespielt. Zwei Mechanismen für
dieselbe Aufgabe wären nur eine Fehlerquelle.

## 5. Vollautomatisch vs. bewusst manuell

| Läuft allein | Bleibt manuell |
|---|---|
| Anwendungs-Images | `terraform apply` für VM-Definitionen |
| Plattform-Charts (Cilium, cert-manager, Traefik) | Talos-Major-Upgrades |
| Kubernetes-Minor via system-upgrade-controller | Firewall-Regeländerungen |
| `apk upgrade` auf den beiden Alpine-VMs per Timer | Datenbank-Majors |

Bei Talos hängt daran der Fallstrick aus Kapitel 6.1: Single-Node braucht
`--preserve`, und bei System-Extensions muss das Upgrade-Image über die Image Factory
mit **derselben Schematic-ID** gebaut werden. Beides gehört fest in die `Plan`-CRD des
Upgrade-Controllers – nicht in eine manuelle Befehlszeile, sonst ist es genau der
Schritt, der beim vierten Mal vergessen wird.

**Benachrichtigung** läuft über den bestehenden Stack: ntfy für fehlgeschlagene
CI-Läufe und Flux-Reconcile-Fehler, Uptime-Kuma für „ist der Dienst nach dem Update
wiedergekommen".

## 6. Umsetzungsreihenfolge

1. `kustomize build` + `kubeconform` + `talosctl validate` als GitHub Action – läuft
   gegen den Ist-Zustand von `k8s/` und `vm/talos-test/`
2. Renovate um `kubernetes`-Manager und Talos-/Kubernetes-Regex erweitern
3. Flux auf dem Test-Cluster, `branch: main`
4. Policy-Checks ergänzen, sobald Kyverno steht
5. Prod-Cluster mit `branch: prod`, Promotion zunächst per Hand
6. Promotion-Workflow automatisieren

Nach Schritt 3 aktualisiert sich der Test-Cluster bereits selbst – der erste Punkt,
an dem das Konstrukt das tut, wofür es gebaut ist.
