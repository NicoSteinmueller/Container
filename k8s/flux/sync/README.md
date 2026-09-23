# Was Flux anwendet

Dieses Verzeichnis ist der `sync.path` der FluxInstance aus [`../../bootstrap/main.tf`](../../bootstrap/main.tf)
und enthält **nur Kustomizations** — je eine pro Gruppe. Die Manifeste selbst
liegen in den Geschwisterverzeichnissen.

| Gruppe | Pfad | Inhalt |
|---|---|---|
| [`core`](Core.yaml) | [`../core`](../core) | alle Namespaces, Admission-Policy |
| [`storage`](Storage.yaml) | [`../storage`](../storage) | `local-path` (Default), `nfs-unraid` |
| [`platform`](Platform.yaml) | [`../platform`](../platform) | cert-manager, CloudNativePG, Reloader |
| [`cert-manager-issuers`](CertManagerIssuers.yaml) | [`../cert-manager-issuers`](../cert-manager-issuers) | eigene CA und ihre Zertifikate |
| [`network`](Network.yaml) | [`../network`](../network) | beide Ingress-Controller, CrowdSec, LB-IPAM |
| [`observability`](Observability.yaml) | [`../observability`](../observability) | Prometheus, Loki/Alloy, metrics-server |
| [`grafana-dashboards`](GrafanaDashboards.yaml) | [`../grafana-dashboards`](../grafana-dashboards) | eigene Dashboards als ConfigMaps |
| [`apps`](Apps.yaml) | [`../apps`](../apps) | Headlamp, whoami |
| [`homelab-secrets`](Secrets.yaml) | eigenes Repo im Gitea | die SOPS-verschlüsselten Secrets |

```
core ──┬── storage ── observability ── grafana-dashboards
       ├── platform ── cert-manager-issuers ── network
       └── apps

homelab-secrets        (eigene Quelle, hängt an nichts)
```

## Warum je Gruppe eine eigene Kustomization

Eine einzige Wurzel-Kustomization wäre weniger Text. Drei Dinge kommen erst mit
der Aufteilung:

- **`dependsOn` statt Retry.** Die Reihenfolge ist gesagt statt erlitten. Vorher
  scheiterte bei jedem Neuaufbau erst einmal, was CRDs brauchte, und kam über
  `retryInterval` zurecht.
- **Fehler bleiben lokal.** Ein kaputtes Manifest in `network` hält `apps` nicht
  mehr auf — vorher scheiterte der Lauf als Ganzes, inklusive Prune-Sperre.
- **Die beiden Sonderfälle hören auf, Sonderfälle zu sein.**
  `cert-manager-issuers` und `grafana-dashboards` brauchten schon immer einen
  eigenen Pfad; jetzt ist das die Regel und keine Erklärung mehr wert.

Der Preis: Eine **neue Gruppe** muss hier eingetragen werden. Eine neue *Datei*
in einer bestehenden Gruppe nicht — kustomize-controller erzeugt die
Ressourcenliste je Pfad selbst aus allen YAML-Dateien darin, Unterverzeichnisse
eingeschlossen. Einzige Ausnahme ist `grafana-dashboards`: Dort liegt wegen des
`configMapGenerator` eine eigene `kustomization.yaml`, und dort ist das
Eintragen der Arbeitsschritt.

## `wait` steht nur, wo jemand wartet

`wait: true` heißt: Die Kustomization meldet sich erst fertig, wenn ihre Objekte
gesund sind. Das ist teuer und nur dort gesetzt, wo eine andere Gruppe die
Zusage braucht — `core`, `platform`, `cert-manager-issuers`, `homelab-secrets`.

Bei den übrigen bedeutet `Ready` nur „angewendet". Für `dependsOn` genügt das,
solange es um die Existenz von Objekten geht (Namespace, StorageClass) und nicht
um laufende Pods.

Kein `dependsOn` zeigt auf `flux-system`: Diese Kustomizations entstehen selbst
daraus, und `flux-system` wartet auf die Gesundheit seiner eigenen Objekte. Das
wäre ein Kreis, und er zeigt sich als zwei ewig „Unknown" stehende
Kustomizations, die nichts darüber sagen, woran es liegt.

## Eine Datei in eine andere Gruppe verschieben

Kein reiner Git-Vorgang: Jedes Objekt trägt die Labels
`kustomize.toolkit.fluxcd.io/name` und `/namespace` seiner Kustomization. Zieht
eine Datei um, wechselt der Besitzer.

Gutmütig ist das, weil kustomize-controller beim Prune überspringt, was
inzwischen einer anderen Kustomization gehört — es gibt kein Zeitfenster, in dem
ein Objekt niemandem gehört und eingesammelt wird. Verlassen sollte man sich
darauf trotzdem nicht bei etwas, das Daten hält: Dort erst die Zielgruppe
anwenden lassen, dann die Quelle entfernen.

```bash
kubectl -n monitoring get ns monitoring \
  -o jsonpath='{.metadata.labels.kustomize\.toolkit\.fluxcd\.io/name}'; echo
```

## Status

```bash
flux get kustomizations
kubectl -n flux-system get kustomization
kubectl -n flux-system describe kustomization <name>   # bei False steht hier der Grund
```

## Egress: wer aus dem Cluster heraus darf

Eingehend ist die Trennung über Zonen und `default-deny-ingress` je Namespace
geregelt. Die Gegenrichtung war es lange nicht — ohne Egress-Regel erreicht
jeder Pod das ganze Heimnetz, den Unraid-Host eingeschlossen.

Jeder Namespace mit eigenen Pods trägt deshalb eine `CiliumNetworkPolicy` mit
`endpointSelector: {}` und einem `egress`-Block; das allein schaltet
Default-Deny für die ausgehende Richtung. Die Begründung je Regel steht in der
jeweiligen Datei.

| Namespace | darf hinaus zu |
|---|---|
| `crowdsec` | CoreDNS · LAPI `:8080` · Internet `:443` (CAPI, Hub) |
| `headlamp` | CoreDNS · kube-apiserver `:6443` |
| `reloader` | CoreDNS · kube-apiserver `:6443` |
| `local-path-storage` | CoreDNS · kube-apiserver `:6443` |
| `cert-manager` | CoreDNS · kube-apiserver `:6443` — kein Internet, die CA ist intern |
| `cnpg-system` | CoreDNS · kube-apiserver `:6443` · Instanzen `:5432`/`:8000` |
| `monitoring` | CoreDNS · kube-apiserver `:6443` · Kubelet `:10250` · node-exporter `:9100` · Scrape-Ziele je Namespace — **kein Internet** |
| `traefik-internal` | + headlamp `:4466` · whoami `:80` · Internet `:443`/`:53` |
| `traefik-public` | + LAPI · whoami · Internet `:443`/`:53` |
| `whoami` | CoreDNS (`kind: NetworkPolicy`, aus dem Chart) |

Ins Heimnetz darf keiner: Die Internet-Regeln sind `toCIDRSet` auf `0.0.0.0/0`
mit RFC 1918 und `169.254.0.0/16` unter `except`.

**Zwei Namespaces haben bewusst keine**, beide weil die Policy dort nicht wirken
*könnte*:

- **`csi-driver-nfs`** — beide Pods laufen auf hostNetwork und tragen die
  Identität des Nodes. Keine NetworkPolicy greift auf sie
  ([../storage/nfs-storage/](../storage/nfs-storage/HelmRelease.yaml)).
- **`kube-system`** — sechs von neun Pods ebenfalls hostNetwork. Adressierbar
  blieben CoreDNS und metrics-server; CoreDNS braucht den Resolver im LAN
  (`dns_servers` aus `vm/talos/terraform.tfvars`). Eine Regel dafür koppelte
  eine Flux-Datei an die tfvars, und ein Fehler nähme die clusterweite
  Namensauflösung mit.

```bash
# Gegenprobe - erwartet: kein Durchkommen
kubectl -n crowdsec exec ds/crowdsec-agent -- nc -z -w3 192.168.178.3 80
kubectl -n kube-system exec ds/cilium -- \
  hubble observe --from-namespace crowdsec --verdict DROPPED --last 50
```

## Woher die Charts kommen

Jede Fremdquelle ist unveränderlich gepinnt. Der Grund in einem Satz:
`kustomize-controller` und `helm-controller` sind an `cluster-admin` gebunden
(`multitenant: false`, ein Autor — siehe [../../bootstrap/README.md](../../bootstrap/README.md)). Was als
Chart hereinkommt, wird mit den höchsten Rechten des Clusters gerendert. Eine
bewegliche Quelle ist damit gleichbedeutend mit fremdem Code als Cluster-Admin.

| Quelle | Pinning |
|---|---|
| `local-path-provisioner` | GitRepository auf **Tag** `v0.0.37` |
| `csi-driver-nfs` | GitRepository auf **Tag** `v4.13.4`, Chart aus `charts/v4.13.4/` |
| Traefik, CrowdSec, Headlamp, metrics-server, Reloader, CloudNativePG, cert-manager, kube-prometheus-stack, Loki, Alloy | HelmRepository über HTTPS in `Sources.yaml` der Gruppe, Chart-Version exakt in der HelmRelease gepinnt |
| Grafana-Dashboards und Alarmregeln | in der Chart, also mit `version:` mitgepinnt — eigene dazu über [`../grafana-dashboards`](../grafana-dashboards) |
| Container-Images | Tag, teils zusätzlich Digest |

Bei `csi-driver-nfs` zeigte die frühere `HelmRepository` auf `…/master/charts`,
wo `4.13.4` auf `…/release-4.12/charts/latest/…` auflöste — ein wanderndes
Verzeichnis auf einem wandernden Branch. Die gepinnte Versionsnummer benannte
einen Eintrag im Index, nicht dessen Inhalt.

Beide Tags hebt jetzt der eingebaute `flux`-Manager von Renovate; der frühere
`customManager` in [renovate.json5](../../../renovate.json5) ist entfallen.

> **Bei einem `csi-driver-nfs`-Update ändern sich drei Zeilen**: `tag:`, der
> `chart:`-Pfad *und* der `ignore:`-Pfad. Renovate hebt nur den ersten. Werden
> die anderen vergessen, findet Flux das Chart nicht — ein lauter Fehler.

**Was offen bleibt**, weil es eine Entscheidung oder einen Schlüssel braucht,
den dieses Repo nicht hat:

- **Keine Signaturprüfung** (`spec.verify`) auf den GitRepositories. Sie setzt
  GPG-signierte Commits und ein Secret mit dem öffentlichen Keyring voraus — eine
  Umstellung der Arbeitsweise, nicht eine Zeile Manifest. Solange sie fehlt, ist
  ein abgeflossenes PAT gleichbedeutend mit Cluster-Admin.
- **Kein `serviceAccountName`** an Kustomizations und HelmReleases. Das ist der
  Weg, `cluster-admin` loszuwerden; er verlangt je Kustomization eine eigene
  Rolle und ist bei einem Autor bewusst nicht gegangen worden.
