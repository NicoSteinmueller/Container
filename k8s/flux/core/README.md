# core

Der Boden, auf dem alle anderen Gruppen stehen — und deshalb die einzige, auf
die alle warten ([`../sync/Core.yaml`](../sync/Core.yaml)).

| Komponente | Inhalt |
|---|---|
| [`Namespaces.yaml`](Namespaces.yaml) | alle Namespaces des Clusters mit ihrer Pod-Security-Stufe |
| [`DefaultDenyIngress.yaml`](DefaultDenyIngress.yaml) | `CiliumClusterwideNetworkPolicy`: eingehend zu für jeden Pod außer in `kube-system` und `flux-system` |
| [`DefaultDenyEgress.yaml`](DefaultDenyEgress.yaml) | dasselbe ausgehend, nur DNS zu CoreDNS ist frei |
| [`PublicIngressPolicy.yaml`](PublicIngressPolicy.yaml) | `ValidatingAdmissionPolicy`: `ingressClassName: public` nur in Namespaces mit `homelab.io/zone=public` |

## Default-Deny, clusterweit

Zwei `CiliumClusterwideNetworkPolicy` statt einer Sperre je Namespace und
Richtung: eingehend alles zu, ausgehend alles bis auf DNS. Damit ist auch ein
Namespace zu, den ein Chart selbst anlegt oder den man in `Namespaces.yaml`
vergisst. Freigaben stehen bei der Komponente in `NetworkPolicies.yaml` und
addieren sich dazu - erlaubt ist, was irgendeine Policy erlaubt.

- **Ausgenommen** sind `kube-system` (CoreDNS - ein Fehler träfe jeden Pod) und
  `flux-system` (ein Fehler sperrte den Weg, auf dem er repariert würde).
- **Webhooks brauchen eine Freigabe.** Der kube-apiserver ist für Cilium nicht
  der eigene Node, sondern `kube-apiserver`. Jede Komponente mit
  Admission-Webhook trägt deshalb eine `CiliumNetworkPolicy` mit
  `fromEntities: [kube-apiserver, host]` auf den Webhook-Port: cert-manager
  (`10250`), CloudNativePG (`9443`), kube-prometheus-stack (`10250`).
- **Probes des kubelet** kommen ohne Freigabe durch, Cilium lässt `host` zu.
- **Ausgehend ist nur DNS pauschal frei.** Die API dagegen nicht: Längst nicht
  jeder Pod braucht sie, und eine pauschale Freigabe öffnete sie jedem
  kompromittierten. Sie steht wie alles Weitere in `<name>-egress` der
  Komponente.
- **Fehlt eine Egress-Freigabe**, hängt die Anwendung in einem Timeout statt
  einer Fehlermeldung. Zu sehen nur mit `hubble observe --type drop`.

Gegenprobe nach einer Änderung - jeder Webhook wird dabei tatsächlich
angerufen:

```bash
kubectl -n flux-system get kustomization core platform
kubectl -n kube-system exec ds/cilium -- hubble observe --last 200 --type drop

# Beide Webhooks - ein Timeout hier heißt: Freigabe fehlt
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

Ohne `pod-security.kubernetes.io/enforce`-Label gilt **`privileged`** — ein Pod
dort dürfte privilegiert laufen, Host-Namespaces betreten und hostPath mounten.
Jeder Namespace trägt seine Stufe deshalb ausdrücklich. Welche, und warum,
steht an den Objekten selbst; hier nur die beiden Punkte, die man kennen sollte:

**hostPath ist schon ab `baseline` ein Verstoß**, nicht erst ab `restricted`.
Das ist der Grund, warum `crowdsec`, `local-path-storage`, `csi-driver-nfs` und
`monitoring` auf `privileged` stehen und nicht eine Stufe tiefer:

```bash
kubectl label --dry-run=server --overwrite ns crowdsec \
  pod-security.kubernetes.io/enforce=baseline
# Warning: crowdsec-agent-…: hostPath volumes
```

**`default` ist der Fall, auf den es ankommt.** Er ist leer — aber ein Manifest
ohne `namespace:` landet genau dort. Nebenwirkung: `kubectl run` und
`kubectl debug` ohne securityContext werden dort abgelehnt. Für einen schnellen
Testpod lästig, und genau so gemeint.

`kube-system`, `flux-system` und `cilium-secrets` bleiben bewusst ohne Stufe;
die Begründung steht im Kopf von [`Namespaces.yaml`](Namespaces.yaml).

## Warum alle Namespaces hier liegen

Damit keine Gruppe auf eine andere warten muss. Die RoleBindings für Traefik
liegen in `monitoring` und `headlamp`, die Egress-Policies bei ihren
Komponenten — lägen die Namespaces jeweils bei der Komponente, hinge `network`
an `observability` und `apps`. So hängt alles an `core` und sonst nichts
aneinander.

Ausnahme ist `whoami`: Den legt das lokale Chart an, Helm besitzt ihn.

## Die zweite Sperre gegen „versehentlich öffentlich"

Ohne `PublicIngressPolicy.yaml` gäbe es genau eine: die Namespace-Liste in
[`../network/ingress-public/`](../network/ingress-public/HelmRelease.yaml). Ein
Namespace zu viel darin, und ein interner Dienst hängt am öffentlichen
Controller. Mit der Policy müssen es zwei Fehler gleichzeitig sein — der Eintrag
in der Liste **und** das Label am Namespace —, und beide stehen in Git.

Nativ und nicht Kyverno: dieselbe Bedingung in derselben Sprache (CEL), nur ohne
Pod, CRD, Webhook und zweiten Controller. Der API-Server wertet sie selbst aus.

```bash
# Beweisfall - erwartet: Ablehnung
kubectl -n headlamp create ingress test --class=public --rule='x.invalid/*=y:80'
```
