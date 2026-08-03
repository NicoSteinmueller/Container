# Dashboard für talos-simple

Headlamp als Cluster-Dashboard für den Ein-Node-Cluster aus
[`vm/talos-simple`](../../vm/talos-simple/). Eigenes Terraform-Modul, eigener
State - siehe die Begründung in [`main.tf`](main.tf).

Warum Headlamp und nicht das Kubernetes-Dashboard oder Rancher: ausführlich in
[`values/headlamp.yaml.tftpl`](values/headlamp.yaml.tftpl).

## Voraussetzungen

- `vm/talos-simple` ist aufgebaut und gesund (`terraform apply` dort war
  erfolgreich)
- `terraform` lokal

## Aufbau

```bash
cd k8s/dashboard
cp terraform.tfvars.example terraform.tfvars   # Werte prüfen
terraform init
terraform apply
```

Voreingestellt: Namespace `headlamp` mit PodSecurity "restricted", ein
ServiceAccount `headlamp` mit reinen Leserechten (`view` plus ein paar
clusterweite Ressourcen), ein zweiter `headlamp-admin` mit `cluster-admin`
aber ohne Pod und ohne Token, dazu metrics-server für die
Auslastungsanzeigen.

## Zugang

Ohne Ingress-Controller und cert-manager in diesem Cluster ist der
Standardweg ein Port-Forward - TLS-geschützt durch den API-Server, kein Token
geht dabei im Klartext übers Netz:

```bash
export KUBECONFIG=../../vm/talos-simple/kubeconfig
kubectl -n headlamp port-forward svc/headlamp 8080:80
```

Im Browser `http://localhost:8080` öffnen. Login mit einem Token:

```bash
# Lesen (8 Stunden gültig)
kubectl -n headlamp create token headlamp --duration=8h

# Ändern (1 Stunde gültig) - danach im Dashboard wieder abmelden
kubectl -n headlamp create token headlamp-admin --duration=1h
```

Alternative für den Aufruf aus dem Heimnetz ohne kubectl:
`service_type = "NodePort"` in `terraform.tfvars` setzen. Das Token geht dann
als unverschlüsseltes HTTP übers LAN - siehe die Abwägung in
[`variables.tf`](variables.tf).

## Metriken

`kubectl top node` / `kubectl top pods` und die Auslastungsanzeigen im
Dashboard laufen über metrics-server, standardmäßig installiert
(`metrics_server_enabled = true`).

Wichtiger Unterschied zu [`k8s/platform`](../platform/): Dort holt sich das
Kubelet ein echtes, CSR-genehmigtes Serverzertifikat
(`serverTLSBootstrap` + `kubelet-csr-approver`), hier nicht - das fehlt in
`vm/talos-simple` bewusst (siehe dessen README). Ohne dieses Zertifikat kann
metrics-server dem Kubelet nicht vertrauen und läuft deshalb mit
`--kubelet-insecure-tls`. Die Abwägung dahinter steht in
[`values/metrics-server.yaml`](values/metrics-server.yaml).

## Was hier bewusst fehlt

- **Ingress, TLS, ein eigener Name.** Kommt mit dem Plattform-Stack aus
  [`k8s/platform`](../platform/) und ersetzt Port-Forward bzw. NodePort.
- **OIDC gegen Keycloak.** Die Werte-Datei legt dafür vor
  (`config.oidc.secret.create: false`), aber es fehlt noch die Anbindung.
- **Geprüftes Kubelet-Zertifikat für metrics-server.** Kommt erst mit
  `serverTLSBootstrap` in `vm/talos-simple` und einem CSR-Approver - siehe
  oben.

## Aufräumen

```bash
terraform destroy
```

Entfernt Namespace, ServiceAccounts, ClusterRoleBindings und die
Helm-Release. Der Cluster selbst (`vm/talos-simple`) bleibt unberührt.
