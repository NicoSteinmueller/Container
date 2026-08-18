# Flux (GitOps) für talos-simple

Push auf `master` soll ausrollen, ohne dass jemand `kubectl apply` von Hand
tippt - dasselbe Automatisierungsgefühl, das Portainer bislang für die
Compose-Stacks liefert. Dieses Modul installiert dafür Flux Operator und
richtet eine `FluxInstance` ein, die dieses Repo beobachtet.

## Warum Flux Operator und nicht Capacitor/Weave GitOps/`flux bootstrap`

Eine Recherche im August 2026 hat die Ausgangslage verschoben:

- **Capacitor** ist inzwischen ein lokales Binary (liest kubeconfig wie
  `talosctl`), kein In-Cluster-Deployment mehr - keine NodePort-fähige
  Oberfläche.
- **Weave GitOps** ist seit der Weaveworks-Schließung 2024 ohne neue
  Releases, u.a. mit einem bekannten Bug bei HelmRelease v2.
- **Flux Operator** (`controlplaneio-fluxcd/flux-operator`, AGPL-3.0, von den
  Flux-Kernmaintainern bei ControlPlane) bringt seit Flux 2.8 (GA Februar
  2026) eine offizielle, aktiv gepflegte Web-Oberfläche mit ("Flux Status
  Page", Port 9080) - read-only, zeigt keine Secrets/ConfigMaps.

Der Operator ersetzt zugleich den klassischen `flux bootstrap`/
`terraform-provider-flux`-Weg: Eine einzige `FluxInstance`-Ressource
beschreibt Distribution, Komponenten und Git-Sync; der Operator installiert
und pflegt die eigentlichen Flux-Controller selbst, statt dass Terraform
Manifeste ins Repo zurückschreibt.

## Anwenden

State **und** Werte liegen in Gitea 
```bash
cd k8s/flux
git -C "$HOMELAB_VALUES" pull
tf init
tf apply
```

Ein Durchlauf genügt, auch gegen einen frischen Cluster. Die FluxInstance
kommt als zweites Helm-Release (`flux-instance` aus demselben Repo wie der
Operator), nicht als `kubernetes_manifest` - siehe unten, "Warum die
FluxInstance ein Helm-Release ist".

Terraform legt das Secret `flux-git-auth` an, aber **leer** - die Werte
selbst trägt niemand über Terraform ein (siehe unten, "Warum das Secret
leer aus Terraform kommt"). Eintragen per kubectl:

```bash
tf output fill_secret
```

liefert den `kubectl patch secret`-Befehl (Headlamp als Alternative, falls
gerade kein kubeconfig zur Hand ist). `<PAT>` ist ein GitHub Personal
Access Token, fein-scoped auf genau dieses Repo
(`NicoSteinmueller/Container`), zunächst nur mit Lesezugriff (Contents:
Read) - Schreibrechte kommen erst dazu, falls später der
image-automation-controller Tags im Repo aktualisieren soll.

Prüfen:

```bash
tf output status_commands
tf output access
```

Ein grüner Zustand heißt: `fluxinstance/flux` zeigt `Ready`, die
`GitRepository flux-system` ebenso (erst nach dem Secret), alle Flux-Pods
laufen.

## Warum das Secret leer aus Terraform kommt

Dieselbe Regel wie bei step-ca und den Headlamp-Tokens
(`k8s/platform/README.md`, `k8s/flux/clusters/talos-cp1/headlamp.yaml`): Was ein Geheimnis ist,
geht nicht durch Terraform-State. Ein PAT als Terraform-Variable wäre im
Klartext lesbar für jeden mit Zugriff auf den State - und der liegt
unverschlüsselt in der Gitea-Package-Registry, geschützt nur durch den Token
aus `TF_HTTP_PASSWORD`.

Das Objekt `kubernetes_secret.flux_git_auth` existiert trotzdem, damit die
FluxInstance einen gültigen `pullSecret`-Namen referenzieren kann - nur mit
leeren Platzhaltern für `username`/`password`. Die echten Werte kommen per
`kubectl patch secret` hinein (siehe oben, `tf output fill_secret`)
und gehen damit direkt an die API, nie durch Terraform-State. Headlamp
(Admin-Token, siehe `k8s/flux/clusters/talos-cp1/headlamp.yaml`) geht alternativ. `lifecycle.ignore_changes
= [data]` auf der Ressource sorgt dafür, dass der nächste `tf apply`
diesen Eintrag nicht wieder auf leer zurücksetzt.

## Warum die FluxInstance ein Helm-Release ist

Naheliegender wäre `kubernetes_manifest` - ein CR, ein Manifest, fertig. Der
Weg funktioniert hier aber nicht: Diese Ressource prüft ihr Manifest schon
beim **Planen** gegen das OpenAPI-Schema des Clusters, und die CRD
`FluxInstance` bringt erst `helm_release.flux_operator` im selben Lauf mit.

`helm_release` rendert dagegen erst zur Laufzeit und kennt das Henne-Ei-Problem
nicht. ControlPlane veröffentlicht die FluxInstance dafür als eigenes Chart
(`flux-instance`) neben dem Operator-Chart. Preis: Die `spec` steht als
`yamlencode`-Values statt als HCL-Objekt, und `flux_instance_chart_version`
will mit `flux_operator_chart_version` zusammen nachgezogen werden - beide
Charts kommen aus demselben Repo und werden gemeinsam veröffentlicht.

`healthcheck.enabled` des Charts bleibt auf dem Default `false`. Angeschaltet
wartete der Release auf einen gesunden Sync - der kann ohne den erst danach
von Hand eingetragenen PAT gar nicht eintreten, der `apply` liefe also
zwangsläufig in seinen Timeout.

## Sicherheits-Abwägung: NodePort ohne Login

Anders als Headlamp (`k8s/flux/clusters/talos-cp1/headlamp.yaml`), das immer einen Bearer-Token verlangt,
hat die Flux-Status-Seite standardmäßig **kein Login**. Sie zeigt dafür weder
Secrets noch ConfigMaps - nur den Reconciliation-Zustand von GitRepository,
Kustomization und Co. `service_type = "NodePort"` (Voreinstellung) bedeutet
also: jeder im Heimnetz sieht diesen Zustand ohne jede Anmeldung. Kein
Zugriff auf Zugangsdaten, aber explizit weniger Kontrolle als beim Dashboard.

Auf `service_type = "ClusterIP"` wechseln, wenn das nicht reichen soll - dann
läuft der Zugang über

```bash
kubectl -n flux-system port-forward svc/flux-operator 9080:9080
```

und ist damit TLS-geschützt durch den API-Server, wie bei Headlamp.

**SSO/OIDC für diese UI nicht aktivieren, ohne vorher den Patch-Stand von
flux-operator zu prüfen** - es gab dazu bereits eine Sicherheitslücke
(GHSA-4xh5-jcj2-ch8q / CVE-2026-23990): Bei leeren OIDC-Claims lief die
Impersonation ins Leere, und Aktionen wurden mit den Rechten des
Flux-Operator-ServiceAccounts statt den eingeschränkten Rechten des
angemeldeten Nutzers ausgeführt. Ohne SSO-Konfiguration betrifft das diesen
Aufbau nicht.

## Warum kein PodSecurity "restricted" für den Namespace

Headlamp bekommt in `k8s/flux/clusters/talos-cp1/headlamp.yaml` bewusst `restricted` - hier nicht.
Kustomize-controller und helm-controller müssen im Cluster anwenden dürfen,
was im beobachteten Pfad steht; das ist der Kern von GitOps, keine
übersehene Härtung. Die eigentliche Kontrolle liegt darin, wer auf
`var.git_branch` (Voreinstellung `master`) schreiben darf - nicht in
PodSecurity-Labels auf `flux-system`.

## Warum `cluster.multitenant = false`

Ein einzelner Autor schreibt auf `master` - dieselbe Vertrauensbasis, die
bislang für Portainers Auto-Deploy galt. Mit `multitenant: true` schränkt
sich `kustomize-controller` von selbst auf definierte Service-Accounts pro
Namespace ein; sinnvoll, sobald mehr als eine Quelle (mehrere Repos, mehrere
Autoren) auf diesen Cluster schreibt. Bis dahin wäre es zusätzliche
Komplexität ohne zusätzlichen Nutzen.

## Erster Workload: whoami

`k8s/flux/clusters/talos-cp1/whoami.yaml` ist die erste Flux-Ressource in
diesem Verzeichnis - eine `HelmRelease`, die das lokale Chart
`k8s/whoami/chart` installiert (Deployment, Service, NetworkPolicy,
Namespace, Ingress). Details zu Chart, Umgebungs-Values und der
NGINX/Traefik-Frage stehen in `k8s/flux/clusters/talos-cp1/README.md` und
`k8s/whoami/README.md`.

## Cluster-Dashboard: Headlamp

`k8s/flux/clusters/talos-cp1/headlamp.yaml` und `metrics-server.yaml` lösen
das frühere Terraform-Modul `k8s/dashboard` ab - Headlamp läuft jetzt wie
whoami als Flux-`HelmRelease`, nur mit einer eigenen `HelmRepository` als
Quelle, weil der Chart fremd ist statt lokal im Repo. Details stehen in
`k8s/flux/clusters/talos-cp1/README.md`.
