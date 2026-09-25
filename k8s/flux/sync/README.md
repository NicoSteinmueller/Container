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
| [`observability`](Observability.yaml) | [`../observability`](../observability) | Prometheus, Loki/Alloy, metrics-server, eigene Dashboards |
| [`observability-rules`](ObservabilityRules.yaml) | [`../observability-rules`](../observability-rules) | eigene Alarmregeln und Scrape-Ziele (`PrometheusRule`, `PodMonitor`) |
| [`apps`](Apps.yaml) | [`../apps`](../apps) | Headlamp, ntfy, whoami, die umgezogenen Dienste |
| [`homelab-secrets`](Secrets.yaml) | eigenes Repo im Gitea | SOPS-verschlüsselte Secrets |

```
core ──┬── storage ── observability ── observability-rules
       ├── platform ── cert-manager-issuers ── network
       └── apps        (auch an platform, storage, homelab-secrets)
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

Ausgehend ist alles zu bis auf DNS für `**.cluster.local`
([`../core/DefaultDenyEgress.yaml`](../core/DefaultDenyEgress.yaml)); was ein
Namespace darüber hinaus braucht, steht in seiner `<name>-egress`. Ins Internet
nur per `toFQDNs` auf einzelne Namen, und genau diese Namen stehen daneben als
`rules.dns` - jeder andere Name bekommt NXDOMAIN (Dashboard „DNS-Blockaden“,
Alarm `DnsAbfrageBlockiert`). Ins Heimnetz darf keiner.

| Namespace | darf außer DNS hinaus zu | DNS-Namen außer `cluster.local` |
|---|---|---|
| `crowdsec` | Agent → LAPI `:8080` · `hub-data.crowdsec.net`, `version.crowdsec.net` `:443` · LAPI zusätzlich `api.crowdsec.net` `:443` | dieselben · Agent: PTR `*.*.*.*.in-addr.arpa` (rDNS) |
| `headlamp`, `reloader`, `local-path-storage`, `cert-manager` | kube-apiserver `:6443` | - |
| `cnpg-system` | kube-apiserver · Instanzen `:5432`/`:8000` | - |
| `monitoring` | kube-apiserver · Kubelet `:10250` · node-exporter `:9100` · Cilium `:9962`–`:9965` · Traefik `:9100` · Scrape-Ziele in `kube-system`/`flux-system` · Alertmanager → ntfy `:8080` - **kein Internet** | - |
| `traefik-internal` | headlamp `:4466` · Grafana `:3000` · whoami `:80` · `acme-v02.api.letsencrypt.org`, `api.hosting.ionos.com` `:443` · 1.1.1.1/8.8.8.8 `:53` | dieselben zwei |
| `traefik-public` | LAPI `:8080` · ntfy `:8080` · `plugins.traefik.io`, `acme-v02.api.letsencrypt.org`, `api.hosting.ionos.com` `:443` · 1.1.1.1/8.8.8.8 `:53` | dieselben drei |
| `ntfy` | nichts | - |
| `kube-system` (metrics-server) | kube-apiserver · Kubelet `:10250` | - |
| `flux-system` | alles (Flux' eigene `allow-egress`) | Git- und Helm-Quellen, `ghcr.io` ([`../core/FluxSystemDns.yaml`](../core/FluxSystemDns.yaml)) |

Keine Regel greift auf hostNetwork-Pods (`csi-driver-nfs`, node-exporter,
Cilium, Control-Plane) und auf CoreDNS selbst - es ist der Resolver.

**Offen:** Traefik fragt für DNS-01 1.1.1.1/8.8.8.8 direkt, am DNS-Proxy
vorbei. Das ist ein zweiter DNS-Weg ohne Namensliste, nur für diese beiden Pods.

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
| Dashboards und Alarmregeln | mit der Chart, eigene in [`../observability/monitoring/dashboards`](../observability/monitoring/dashboards) |
| Container-Images | Tag, teils mit Digest |

Renovate hebt die Tags (`flux`-Manager).

**Offen:** keine Signaturprüfung (`spec.verify`) auf den GitRepositories - ein
abgeflossenes PAT ist damit Cluster-Admin; kein `serviceAccountName` je
Kustomization, bei einem Autor bewusst.
