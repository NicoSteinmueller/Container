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
([`platform/reloader.yaml`](platform/reloader.yaml)). Dafür ist in keinem Chart
etwas einzutragen — aber der Namespace gehört in die Liste dort.
