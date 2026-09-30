# sync

| Gruppe | Pfad | Inhalt |
|---|---|---|
| [`core`](Core.yaml) | [`../core`](../core) | Namespaces, Default-Deny, Admission-Policy |
| [`storage`](Storage.yaml) | [`../storage`](../storage) | `local-path` (Default), `nfs-unraid` |
| [`platform`](Platform.yaml) | [`../platform`](../platform) | cert-manager, CloudNativePG, Reloader |
| [`cert-manager-issuers`](CertManagerIssuers.yaml) | [`../cert-manager-issuers`](../cert-manager-issuers) | eigene CA und ihre Zertifikate |
| [`network`](Network.yaml) | [`../network`](../network) | Ingress-Controller, CrowdSec, LB-IPAM |
| [`observability`](Observability.yaml) | [`../observability`](../observability) | Prometheus, Loki/Alloy, metrics-server, eigene Dashboards |
| [`observability-rules`](ObservabilityRules.yaml) | [`../observability-rules`](../observability-rules) | eigene Alarmregeln und Scrape-Ziele (`PrometheusRule`, `PodMonitor`) |
| [`apps`](Apps.yaml) | [`../apps`](../apps) | Headlamp, it-tools, Navidrome, ntfy, whoami, die umgezogenen Dienste |
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
- **Kein `dependsOn` auf `flux-system`** - das wäre ein Kreis.
- **Eine Datei in eine andere Gruppe verschieben** wechselt den Besitzer
  (Label `kustomize.toolkit.fluxcd.io/name`). Prune überspringt fremde Objekte;
  bei Daten trotzdem erst das Ziel anwenden lassen, dann die Quelle entfernen.

## Egress

Ausgehend ist alles zu bis auf DNS für `**.cluster.local`
([`../core/DefaultDenyEgress.yaml`](../core/DefaultDenyEgress.yaml)); was ein
Namespace darüber hinaus braucht, steht in seiner `<name>-egress`. Ins Internet
nur per `toFQDNs` auf einzelne Namen, und genau diese Namen stehen daneben als
`rules.dns` - jeder andere Name bekommt NXDOMAIN (Dashboard „DNS-Blockaden“,
Alarm `DnsAbfrageBlockiert`). Ins Heimnetz darf keiner.
