# Flux (GitOps)

Push auf `var.git_branch` rollt aus. Hier liegt nur, was Flux **dauernd**
anwendet; wie Flux **einmal** in den Cluster kommt, steht in
[`../bootstrap/`](../bootstrap/README.md). Gruppen, Abhängigkeiten und
clusterweite Regeln: [`sync/README.md`](sync/README.md).

```
sync/                    eine Kustomization je Gruppe
core/ storage/ platform/ network/ observability/ apps/
cert-manager-issuers/    eigene Gruppe: CRDs entstehen erst mit cert-manager
observability-rules/     eigene Gruppe: CRDs entstehen erst mit kube-prometheus-stack
```

## Aufbau einer Gruppe

```
network/
├── README.md                 Gruppe und das Gemeinsame
├── Sources.yaml              HelmRepositories der Gruppe
├── lb-ipam/                  …
└── ingress-public/
    ├── README.md             das Warum der Komponente
    ├── HelmRelease.yaml      Kopfkommentar, dann die HelmRelease
    ├── NetworkPolicies.yaml  NetworkPolicy, CiliumNetworkPolicy
    ├── RBAC.yaml             ServiceAccount, (Cluster)Role, Bindings
    └── DynamicConfig.yaml    alles Weitere eine Datei je Art (ConfigMap, TLSOption …)
```

- **Ordner nur ab zwei Dateien.** Eine Komponente mit einer Datei liegt als
  `<Komponente>.yaml` in der Gruppe (`apps/Whoami.yaml`); eine Gruppe aus einer
  Komponente trägt deren Dateien selbst (`cert-manager-issuers/`). Flux sammelt
  Unterordner von selbst ein.
- **Dateien PascalCase, Ordner kebab-case.** Abkürzungen wie im Kind
  (`TLSOption.yaml`, `RBAC.yaml`). Ausnahmen: `kustomization.yaml` (verlangt
  kustomize) und die Dashboard-JSONs (der Dateiname wird zum ConfigMap-Schlüssel).
- **Eine `kustomization.yaml` im Unterordner** nimmt Flux als Ganzes auf, statt
  die Dateien darin einzusammeln - nur wo ein Generator sie braucht
  (`observability/monitoring/dashboards/`).
- **`HelmRelease.yaml` ist die Hauptdatei**, ihr Kopfkommentar sagt, was die
  Komponente ist; andere Dateien beginnen mit `# <komponente> - <was>`.
- **Reihenfolge in einer Datei:** was andere braucht, zuerst - Quelle vor
  HelmRelease, ServiceAccount vor Rollen.
- **HelmRelease:** `releaseName`, `targetNamespace` und `storageNamespace`
  ausdrücklich, die beiden Namespaces gleich - sonst landet der Helm-Stand in
  `flux-system`. Einen davon später ändern heißt: Flux deinstalliert und
  installiert neu. Zeitlimits als `spec.timeout`, nicht je Aktion.
- **Quellen in `Sources.yaml`**, weil eine Quelle mehreren gehören kann - wer
  eine Komponente entfernt, soll nicht nebenbei einer anderen die Quelle
  wegnehmen. Die Version pinnt die HelmRelease, nicht die Quelle.
  Ausnahme `storage/`: Dort pinnt die `GitRepository` selbst die Version und
  steht deshalb in `HelmRelease.yaml`.
- **Verweise nennen Dateien** (`RBAC.yaml`), nicht „oben/unten“; betrifft etwas
  mehrere Dateien, den Ordner.
- **READMEs kurz**: das Warum und die Fallen, nicht was im Manifest steht.

## Secrets

Alle Zugangsdaten liegen SOPS-verschlüsselt im Gitea-Repo
[`homelab-secrets`](https://git.local.nico-steinmueller.de/nico/homelab-secrets),
nicht hier - auch Ciphertext gehört nicht nach GitHub. Die drei Secrets, mit
denen Flux überhaupt dorthin kommt, legt der Bootstrap an.

**Rotation:** Wert in `homelab-secrets` ändern und pushen. Flux schreibt das
Secret neu, [Reloader](platform/reloader/README.md) startet die Nutzer neu -
sofern ihr Namespace in seiner Liste steht.
