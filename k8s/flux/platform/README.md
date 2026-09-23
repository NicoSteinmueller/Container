# platform

Controller, auf denen die Dienste aufsetzen.

| Komponente | Was |
|---|---|
| [`cert-manager/`](cert-manager) | interne CA für clusterinterne Zertifikate |
| [`cloudnative-pg/`](cloudnative-pg) | Postgres-Operator |
| [`reloader/`](reloader) | startet neu, was ein geändertes Secret benutzt |
| [`Sources.yaml`](Sources.yaml) | HelmRepositories `jetstack`, `cloudnative-pg`, `stakater` |

`wait: true` ([`../sync/Platform.yaml`](../sync/Platform.yaml)), weil
`cert-manager-issuers` und dahinter `network` darauf warten. Hängt eine Release,
steht die Kette.
