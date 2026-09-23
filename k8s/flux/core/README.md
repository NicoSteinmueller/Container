# core

Der Boden, auf dem alle Gruppen stehen - und die einzige, auf die alle warten.

| Komponente | Was |
|---|---|
| [`namespaces/`](namespaces/Restricted.yaml) | alle Namespaces mit Pod-Security-Stufe: `Restricted.yaml`, `Privileged.yaml` |
| [`DefaultDenyIngress.yaml`](DefaultDenyIngress.yaml) | eingehend zu für jeden Pod außer in `kube-system`, `flux-system` |
| [`DefaultDenyEgress.yaml`](DefaultDenyEgress.yaml) | ausgehend zu bis auf DNS, für dieselben Pods |
| [`PublicIngressPolicy.yaml`](PublicIngressPolicy.yaml) | `ingressClassName: public` nur in Namespaces mit `homelab.io/zone=public` |

**Alle Namespaces hier**, damit jede Gruppe nur an `core` hängt: Traefiks
RoleBindings liegen z. B. in `monitoring` und `headlamp` - sonst hinge `network`
an `observability` und `apps`.

## Default-Deny

Zwei `CiliumClusterwideNetworkPolicy` statt einer Sperre je Namespace - auch ein
Namespace, den ein Chart anlegt oder den man vergisst, ist zu. Freigaben stehen
in `NetworkPolicies.yaml` der Komponente und addieren sich.

- **Ausgenommen:** `kube-system` (ein Fehler träfe CoreDNS und damit jeden Pod),
  `flux-system` (ein Fehler sperrte den Weg, auf dem er repariert würde).
- **Webhooks** brauchen eine Freigabe `fromEntities: [kube-apiserver, host]`
  auf ihren Port: cert-manager `10250`, CloudNativePG `9443`,
  kube-prometheus-stack `10250`. kubelet-Probes kommen ohne durch.
- **Ausgehend** ist nur DNS pauschal frei. Die API nicht - nicht jeder Pod
  braucht sie; sie steht in `<name>-egress` der Komponente.
- **Fehlt eine Freigabe**, gibt es einen Timeout statt einer Fehlermeldung.

```bash
kubectl -n kube-system exec ds/cilium -- hubble observe --last 200 --type drop

# Beide Webhooks - ein Timeout heißt: Freigabe fehlt
kubectl create --dry-run=server -f - <<'Y'
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {name: probe, namespace: cert-manager}
spec: {secretName: probe, dnsNames: [probe.local], issuerRef: {name: homelab-ca, kind: ClusterIssuer}}
---
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: {name: probe, namespace: cnpg-system}
spec: {instances: 1, storage: {size: 1Gi}}
Y
```

## Pod Security

Ohne `enforce`-Label gilt `privileged`, deshalb trägt jeder Namespace seine
Stufe ausdrücklich. Die Ausnahmen stehen in
[`namespaces/Privileged.yaml`](namespaces/Privileged.yaml), jede mit Grund -
hostPath verbietet schon `baseline`.

- **`default`** ist leer, aber ein Manifest ohne `namespace:` landet dort. Als
  Nebenwirkung scheitern `kubectl run`/`debug` ohne securityContext - gewollt.
- **Ohne Stufe:** `kube-system` (Cilium bräuche mehr als `baseline`),
  `flux-system` (die Controller müssen anwenden, was im Repo steht),
  `cilium-secrets` (gehört der Talos-Machine-Config, keine Pods), `whoami`
  (legt das Chart an).

## Zweite Sperre gegen „versehentlich öffentlich“

Ohne `PublicIngressPolicy.yaml` reichte ein Namespace zu viel in der Liste von
`ingress-public`. Mit ihr müssen es zwei Fehler sein: der Listeneintrag **und**
das Label. Native `ValidatingAdmissionPolicy` statt Kyverno - dieselbe CEL-Regel
ohne eigenen Controller.

```bash
kubectl -n headlamp create ingress test --class=public --rule='x.invalid/*=y:80'   # erwartet: Ablehnung
```
