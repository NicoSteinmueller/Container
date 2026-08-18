# Flux (GitOps)

Push auf `var.git_branch` rollt aus, ohne `kubectl apply` von Hand - dieselbe
Automatik, die Portainer für die Compose-Stacks liefert. Das Modul installiert
Flux Operator und eine `FluxInstance`, die dieses Repo beobachtet.

| | |
|---|---|
| Quelle | `k8s/flux/clusters/talos-cp1` aus diesem Repo (`sync_path`) |
| Zugang | Flux-Status-Seite, NodePort `30081`, ohne Login |
| Secret | `flux-git-auth`, leer angelegt, per kubectl befüllt |

## Anwenden

State **und** Werte liegen in Gitea

```bash
cd k8s/flux
git -C "$HOMELAB_VALUES" pull
tf init
tf apply
```

Ein Durchlauf genügt, auch gegen einen frischen Cluster. Danach den PAT
eintragen - `tf output fill_secret` liefert den `kubectl patch`-Befehl.
`<PAT>` ist ein GitHub Personal Access Token, fein-scoped auf
`NicoSteinmueller/Container`, nur `Contents: Read` (Schreibrechte erst, falls
später der image-automation-controller Tags setzen soll).

Prüfen mit `tf output status_commands` und `tf output access`: `fluxinstance/flux`
und `GitRepository flux-system` auf `Ready`, alle Flux-Pods laufen.

## Entscheidungen

**Secret leer aus Terraform.** Das Objekt existiert nur, damit
die FluxInstance einen gültigen `pullSecret`-Namen hat; `ignore_changes = [data]`
hält den per kubectl eingetragenen Wert.

**NodePort ohne Login.** Die Status-Seite verlangt anders als Headlamp kein
Token, zeigt dafür weder Secrets noch ConfigMaps - jeder im Heimnetz sieht den
Reconciliation-Zustand. Reicht das nicht, `service_type = "ClusterIP"` und
`kubectl -n flux-system port-forward svc/flux-operator 9080:9080`.

**Kein PodSecurity `restricted` auf `flux-system`.** Kustomize- und
helm-controller müssen anwenden dürfen, was im beobachteten Pfad steht - das ist
GitOps, keine übersehene Härtung. Die Kontrolle liegt darin, wer auf
`var.git_branch` schreiben darf.

**`cluster.multitenant = false`.** Ein einzelner Autor schreibt auf den Branch.
`true` schränkt kustomize-controller auf Service-Accounts pro Namespace ein -
sinnvoll, sobald mehrere Repos oder Autoren auf den Cluster schreiben.

## Workloads

`clusters/talos-cp1/` enthält whoami (lokales Chart), Headlamp und
metrics-server (fremde Charts) - Details im
[README dort](clusters/talos-cp1/README.md).
