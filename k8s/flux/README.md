# Flux (GitOps)

Push auf `var.git_branch` rollt aus, ohne `kubectl apply` von Hand — dieselbe
Automatik, die Portainer für die Compose-Stacks liefert. Dieses Verzeichnis
enthält nur die Manifeste, die Flux **dauernd** anwendet. Wie Flux selbst
**einmal** in den Cluster kommt, steht in [`../bootstrap/`](../bootstrap/README.md).

## Aufbau

```
sync/                             was Flux anwendet: eine Kustomization je Gruppe
core/ storage/ platform/          die Manifeste dieser Gruppen
network/ observability/ apps/
cert-manager-issuers/             eigener Pfad: CRDs entstehen erst mit dem Release
grafana-dashboards/               eigener Pfad: braucht eine kustomization.yaml
```

### Innerhalb einer Gruppe

Alle Gruppen sind gleich gebaut: ein Ordner je Komponente, darin Dateien mit
festen Namen. Flux sammelt die Unterordner von selbst ein, es braucht keine
`kustomization.yaml`.

**Dateinamen in PascalCase**, Ordner in kebab-case wie die Kubernetes-Namen
(`ingress-public/HelmRelease.yaml`). Abkürzungen schreiben sich wie im Kind:
`TLSOption.yaml`, `IPPool.yaml`, `RBAC.yaml`. Ausnahmen: `kustomization.yaml`,
den Namen verlangt kustomize, und die Dashboard-JSONs in `grafana-dashboards/` -
aus ihrem Dateinamen wird der Schlüssel in der ConfigMap.

Ein Ordner nur, wenn er mehr als eine Datei hält - sonst wäre er Ordner um
eine Datei:

- **Komponente mit einer Datei** liegt als `<Komponente>.yaml` direkt in der
  Gruppe (`apps/Whoami.yaml`, `core/PublicIngressPolicy.yaml`,
  `observability/Loki.yaml`).
- **Gruppe aus einer Komponente** trägt deren Dateien selbst
  (`cert-manager-issuers/`, `grafana-dashboards/`).

```
network/
├── README.md                 Gruppe und Komponenten, das Warum
├── Sources.yaml              die HelmRepositories der Gruppe
├── lb-ipam/                  …
└── ingress-public/
    ├── HelmRelease.yaml      Kopfkommentar der Komponente, dann die HelmRelease
    ├── NetworkPolicies.yaml  NetworkPolicy und CiliumNetworkPolicy
    ├── RBAC.yaml             ServiceAccount, (Cluster)Role, Bindings
    ├── Middlewares.yaml      alles Weitere: eine Datei je Art,
    └── ...                   IngressClass.yaml, TLSOption.yaml, StorageClass.yaml …
```

- **`HelmRelease.yaml`** ist die Hauptdatei: Ihr Kopfkommentar sagt, was die
  Komponente ist. Hat eine Komponente keine HelmRelease (`lb-ipam`,
  `cert-manager-issuers`), trägt die erste Datei nach Art diesen Kopf.
- **Andere Dateien** beginnen mit einer Zeile `# <komponente> - <was>`.
- **Reihenfolge** der Objekte in einer Datei: was andere braucht, zuerst -
  Quelle vor HelmRelease, ServiceAccount vor Rollen und Bindings. Gelesen wird
  eine Komponente am besten in der Folge Policies → RBAC → Konfiguration →
  HelmRelease.
- **`Sources.yaml`** statt bei der Komponente: Eine Quelle kann mehreren
  gehören (traefik), und wer eine Komponente entfernt, soll den anderen nicht
  die Quelle wegnehmen. Ausnahme sind die `GitRepository`-Quellen in
  `storage/`: Dort pinnt die Quelle selbst die Version (Tag und Chart-Pfad),
  sie steht deshalb in `HelmRelease.yaml` direkt vor der HelmRelease.
- **Verweise** zwischen Dateien nennen die Datei (`RBAC.yaml`,
  `../lb-ipam/IPPool.yaml`), nicht „oben“ oder „unten“. Betrifft etwas mehrere
  Dateien einer Komponente - etwa einen Namespace für Traefik freischalten -,
  zeigt der Verweis auf den Ordner.

Was in welcher Gruppe liegt, wie sie voneinander abhängen und welche Regeln für
alle gelten (Egress, Herkunft der Charts), steht in
[`sync/README.md`](sync/README.md). Jede Gruppe hat ihr eigenes README.

## Secrets

Alle Zugangsdaten liegen SOPS-verschlüsselt im Gitea-Repo `homelab-secrets`,
nicht hier: Dieses Repo geht öffentlich nach GitHub, und auch Ciphertext soll
dort nicht liegen. Der Umgang damit — anlegen, ändern, Schlüssel wechseln —
steht im [README von homelab-secrets](https://git.local.nico-steinmueller.de/nico/homelab-secrets).

Die drei Secrets, die Flux braucht, um überhaupt an `homelab-secrets` zu
kommen, legt der Bootstrap an: [`../bootstrap/README.md`](../bootstrap/README.md).

### Rotation

Wert in `homelab-secrets` ändern, committen, pushen. Flux schreibt das Secret
neu, und Reloader startet neu, was es benutzt
([`platform/reloader/HelmRelease.yaml`](platform/reloader/HelmRelease.yaml)).
Dafür ist in keinem Chart etwas einzutragen — aber der Namespace gehört in die
Liste dort.
