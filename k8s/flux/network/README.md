# network

Was Verkehr in den Cluster lässt, und unter welchen Adressen.

| Komponente | Was |
|---|---|
| [`lb-ipam/`](lb-ipam) | LAN-Adressen `.231`/`.232` und ihre Ankündigung |
| [`ingress-internal/`](ingress-internal) | Traefik fürs Heimnetz, IngressClass `internal`, `.231` |
| [`ingress-public/`](ingress-public) | Traefik fürs Internet, IngressClass `public`, `.232` |
| [`crowdsec/`](crowdsec) | LAPI und Agent hinter `ingress-public` |
| [`Sources.yaml`](Sources.yaml) | HelmRepositories `traefik`, `crowdsec` |

`dependsOn: cert-manager-issuers` ([`../sync/Network.yaml`](../sync/Network.yaml)),
weil der CrowdSec-Chart `Certificate`-Objekte gegen `homelab-ca` templatet.

**Zwei Controller statt zwei Entrypoints:** eigener Namespace, eigene Adresse,
eigenes RBAC, eigener Zertifikatsspeicher. Die Fritzbox kennt nur `.232`.

**Ein Dienst bekommt einen Controller** über drei Einträge im Ordner des
Controllers - fehlt einer, bleibt es still:

- `providers.kubernetesIngress.namespaces` und `…kubernetesCRD.namespaces` in
  `HelmRelease.yaml`
- eine RoleBinding in `RBAC.yaml`
- ein `toEndpoints`-Block in `<controller>-egress` (`NetworkPolicies.yaml`)

```bash
kubectl get ingressclass; kubectl get ingress -A     # ADDRESS .231 bzw. .232
curl -k https://whoami.k8s.nico-steinmueller.de
kubectl -n kube-system exec ds/cilium -- hubble observe --last 200 --type drop
```
