# network

Was Verkehr in den Cluster lässt, und unter welchen Adressen.

| Komponente | Was |
|---|---|
| [`lb-ipam/`](lb-ipam) | LAN-Adressen `.231`/`.232` und ihre Ankündigung |
| [`ingress-internal/`](ingress-internal) | Traefik fürs Heimnetz, `.231` |
| [`ingress-public/`](ingress-public) | Traefik fürs Internet, `.232` |
| [`crowdsec/`](crowdsec) | LAPI und Agent hinter `ingress-public` |
| [`Sources.yaml`](Sources.yaml) | HelmRepositories `traefik`, `crowdsec` |

`dependsOn: cert-manager-issuers` ([`../sync/Network.yaml`](../sync/Network.yaml)),
weil der CrowdSec-Chart `Certificate`-Objekte gegen `homelab-ca` templatet.

**Zwei Controller statt zwei Entrypoints:** eigener Namespace, eigene Adresse,
eigener Zertifikatsspeicher. Die Fritzbox kennt nur `.232`.

**Keine Ingress-Objekte, keine Rechte.** Beide Controller lesen keine
Kubernetes-Objekte; die Routen stehen in `ingress-*/DynamicConfig.yaml`
(File-Provider). Ein Kubernetes-Provider läse in jedem bedienten Namespace alle
Secrets, auch den DB-Zugang eines Dienstes. Ein Dienst bekommt einen Controller
über drei Einträge - fehlt einer, bleibt es still:

- Router und Service in `DynamicConfig.yaml` des Controllers
- ein `toEndpoints`-Block in `<controller>-egress` (`NetworkPolicies.yaml`)
- im Ziel-Namespace eine Policy, die den Controller hereinlässt

```bash
kubectl get ingress -A                                # erwartet: leer
curl -k https://whoami.k8s.nico-steinmueller.de
kubectl -n kube-system exec ds/cilium -- hubble observe --last 200 --type drop
```
