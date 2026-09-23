# sync

Der `sync.path` der FluxInstance ([`../../bootstrap/main.tf`](../../bootstrap/main.tf)):
nur Kustomizations, eine je Gruppe.

| Gruppe | Pfad | Inhalt |
|---|---|---|
| [`core`](Core.yaml) | [`../core`](../core) | Namespaces, Default-Deny, Admission-Policy |
| [`storage`](Storage.yaml) | [`../storage`](../storage) | `local-path` (Default), `nfs-unraid` |
| [`platform`](Platform.yaml) | [`../platform`](../platform) | cert-manager, CloudNativePG, Reloader |
| [`cert-manager-issuers`](CertManagerIssuers.yaml) | [`../cert-manager-issuers`](../cert-manager-issuers) | eigene CA und ihre Zertifikate |
| [`network`](Network.yaml) | [`../network`](../network) | Ingress-Controller, CrowdSec, LB-IPAM |
| [`observability`](Observability.yaml) | [`../observability`](../observability) | Prometheus, Loki/Alloy, metrics-server |
| [`grafana-dashboards`](GrafanaDashboards.yaml) | [`../grafana-dashboards`](../grafana-dashboards) | eigene Dashboards als ConfigMaps |
| [`apps`](Apps.yaml) | [`../apps`](../apps) | Headlamp, whoami |
| [`homelab-secrets`](Secrets.yaml) | eigenes Repo im Gitea | SOPS-verschlüsselte Secrets |

```
core ──┬── storage ── observability ── grafana-dashboards
       ├── platform ── cert-manager-issuers ── network
       └── apps
homelab-secrets        (eigene Quelle, hängt an nichts)
```

## Regeln

- **Eine Kustomization je Gruppe**: `dependsOn` statt Retry, und ein Fehler in
  einer Gruppe hält die anderen nicht auf. Eine neue *Gruppe* muss hier
  eingetragen werden, eine neue *Datei* nicht.
- **`wait: true` nur, wo jemand wartet**: `core`, `platform`,
  `cert-manager-issuers`, `homelab-secrets`. Sonst heißt `Ready` nur
  „angewendet“.
- **Kein `dependsOn` auf `flux-system`** - das wäre ein Kreis, sichtbar nur als
  zwei ewig „Unknown“ stehende Kustomizations.
- **Eine Datei in eine andere Gruppe verschieben** wechselt den Besitzer
  (Label `kustomize.toolkit.fluxcd.io/name`). Prune überspringt fremde Objekte;
  bei Daten trotzdem erst das Ziel anwenden lassen, dann die Quelle entfernen.

```bash
kubectl -n flux-system get kustomization
kubectl -n flux-system describe kustomization <name>   # bei False steht hier der Grund
```

## Egress

Ausgehend ist alles zu bis auf DNS
([`../core/DefaultDenyEgress.yaml`](../core/DefaultDenyEgress.yaml)); was ein
Namespace darüber hinaus braucht, steht in seiner `<name>-egress`. Ins Heimnetz
darf keiner: Internet-Regeln sind `toCIDRSet` auf `0.0.0.0/0` ohne RFC 1918 und
`169.254.0.0/16`.

| Namespace | darf außer DNS hinaus zu |
|---|---|
| `crowdsec` | LAPI `:8080` · Internet `:443` (CAPI, Hub) |
| `headlamp`, `reloader`, `local-path-storage`, `cert-manager` | kube-apiserver `:6443` |
| `cnpg-system` | kube-apiserver · Instanzen `:5432`/`:8000` |
| `monitoring` | kube-apiserver · Kubelet `:10250` · node-exporter `:9100` · Scrape-Ziele - **kein Internet** |
| `traefik-internal` | kube-apiserver · headlamp `:4466` · Grafana `:3000` · whoami `:80` · Internet `:443`/`:53` (ACME) |
| `traefik-public` | Node (`host`, darüber die API) · LAPI `:8080` · whoami `:80` · Internet `:443`/`:53` (ACME) |

Keine Regel greift auf hostNetwork-Pods (`csi-driver-nfs`, node-exporter, die
meisten in `kube-system`). `kube-system` ist zudem ausgenommen: CoreDNS braucht
den Resolver im LAN, und eine Regel dafür koppelte Flux an die tfvars.

```bash
kubectl -n crowdsec exec ds/crowdsec-agent -- nc -z -w3 192.168.178.3 80   # erwartet: kein Durchkommen
```

## Woher die Charts kommen

`kustomize-controller` und `helm-controller` laufen als `cluster-admin`
(`multitenant: false`, [../../bootstrap/README.md](../../bootstrap/README.md)).
Eine bewegliche Chart-Quelle wäre fremder Code als Cluster-Admin - deshalb ist
jede gepinnt:

| Quelle | Pinning |
|---|---|
| `local-path-provisioner`, `csi-driver-nfs` | GitRepository auf Tag |
| alle übrigen Charts | HelmRepository in `Sources.yaml`, Version exakt in der HelmRelease |
| Dashboards und Alarmregeln | mit der Chart, eigene in [`../grafana-dashboards`](../grafana-dashboards) |
| Container-Images | Tag, teils mit Digest |

Renovate hebt die Tags (`flux`-Manager).

**Offen:** keine Signaturprüfung (`spec.verify`) auf den GitRepositories - ein
abgeflossenes PAT ist damit Cluster-Admin; kein `serviceAccountName` je
Kustomization, bei einem Autor bewusst.
