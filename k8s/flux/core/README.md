# core

Der Boden, auf dem alle Gruppen stehen - und die einzige, auf die alle warten.

| Komponente | Was |
|---|---|
| [`namespaces/`](namespaces/Restricted.yaml) | alle Namespaces mit Pod-Security-Stufe: `Restricted.yaml`, `Privileged.yaml` |
| [`DefaultDenyIngress.yaml`](DefaultDenyIngress.yaml) | eingehend zu für jeden Pod außer in `kube-system`, `flux-system` |
| [`DefaultDenyEgress.yaml`](DefaultDenyEgress.yaml) | ausgehend zu bis auf DNS für `**.cluster.local` - dazu `kube-system` außer CoreDNS |
| [`FluxSystemDns.yaml`](FluxSystemDns.yaml) | DNS-Allowlist für `flux-system` (Git- und Helm-Quellen) |
| [`DnsAllowlist.yaml`](DnsAllowlist.yaml) | keine Freigabe auf Port 53 ohne Namensliste |
| [`NoIngressObjects.yaml`](NoIngressObjects.yaml) | kein Ingress und keine IngressRoute - Routen stehen im File-Provider |
| [`ServiceExposure.yaml`](ServiceExposure.yaml) | LoadBalancer nur für die Ingress-Controller, ohne NodePorts; NodePort nur für die Flux-Statusseite |

**Alle Namespaces hier**, damit jede Gruppe nur an `core` hängt: Objekte einer
Gruppe liegen oft im Namespace einer anderen (die Rollen von
`observability` etwa in `monitoring`, das CrowdSec-CA-Zertifikat in
`traefik-public`).

## Default-Deny

Zwei `CiliumClusterwideNetworkPolicy` statt einer Sperre je Namespace - auch ein
Namespace, den ein Chart anlegt oder den man vergisst, ist zu. Freigaben stehen
in `NetworkPolicies.yaml` der Komponente und addieren sich.

- **Ausgenommen:** `kube-system` (ein Fehler träfe CoreDNS und damit jeden Pod),
  `flux-system` (ein Fehler sperrte den Weg, auf dem er repariert würde).
  Ausgehend gilt das nur noch für CoreDNS und `flux-system`, siehe unten.
- **Webhooks** brauchen eine Freigabe `fromEntities: [kube-apiserver, host]`
  auf ihren Port: cert-manager `10250`, CloudNativePG `9443`,
  kube-prometheus-stack `10250`. kubelet-Probes kommen ohne durch.
- **Ausgehend** ist nur DNS pauschal frei, und nur für `**.cluster.local`.
  Die API nicht - nicht jeder Pod braucht sie; sie steht in `<name>-egress`
  der Komponente.
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

## DNS-Allowlisten

Jede DNS-Abfrage eines Pods läuft durch Ciliums DNS-Proxy und geht nur durch,
wenn eine Policy den Namen erlaubt; alles andere bekommt REFUSED. Ohne das
reichte CoreDNS jeden Namen ins Internet weiter - ein Rückkanal (DNS-Tunnel)
für jeden Pod, auch ohne Egress-Freigabe.

- **Für alle** `**.cluster.local` ([`DefaultDenyEgress.yaml`](DefaultDenyEgress.yaml)).
- **Externe Namen** nur, wo auch eine Verbindung dorthin erlaubt ist:
  `rules.dns` neben den `toFQDNs` der Komponente. Listen addieren sich.
- **Die Falle** (nachgemessen): Eine Freigabe auf Port 53 ohne `rules.dns` -
  als CiliumNetworkPolicy oder NetworkPolicy, in irgendeiner Policy des Pods -
  lässt wieder jeden Namen durch. Freigaben ohne Port nicht.
  [`DnsAllowlist.yaml`](DnsAllowlist.yaml) lehnt sie deshalb ab, ebenso
  `matchPattern: "*"`. Ausnahme: Port 53 zu festen externen Adressen
  (`toCIDR`, Traefik → 1.1.1.1).
- **`flux-system`**: Die Sperre kommt von Flux' `allow-egress` (alles erlaubt
  außer DNS, das die Liste regelt). Fehlt ein Name, den der Sync selbst
  braucht, repariert sich Flux nicht aus Git - dann
  `kubectl -n flux-system delete cnp flux-dns flux-source-dns flux-operator-dns`,
  Fix pushen, Flux legt sie neu an.
- **`enableDefaultDeny: false`** taugt nicht für eine Liste: Ohne
  Default-Deny leitet der Proxy auch nicht gelistete Namen weiter
  (nachgemessen).
- **Neue Quelle, neuer Dienst mit Internet:** Host in `toFQDNs` und
  `rules.dns`, sonst REFUSED und Alarm.

```bash
# abgelehnte Namen live
kubectl -n kube-system exec ds/cilium -c cilium-agent -- hubble observe --protocol DNS --verdict DROPPED --follow
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
  `cilium-secrets` (gehört der Talos-Machine-Config, keine Pods).

## Keine Ingress-Objekte

Beide Traefik-Controller lesen keine Kubernetes-Objekte; ihre Routen stehen in
[`../network/ingress-*/DynamicConfig.yaml`](../network/README.md). Ein Ingress
oder eine IngressRoute bliebe still unbedient - `NoIngressObjects.yaml` lehnt
das Anlegen deshalb ab und nennt den richtigen Ort. Ein Chart, das ab Werk einen
Ingress mitbringt, scheitert damit laut: `ingress.enabled: false`. Native
`ValidatingAdmissionPolicy`, kein eigener Controller. Nur `CREATE`, damit Helm
Altobjekte noch löschen kann.

Das Label `homelab.io/zone` an den Namespaces wertet niemand aus; es
dokumentiert, wer von außen erreichbar ist.

```bash
# erwartet: beide abgelehnt
kubectl -n headlamp create ingress test --class=internal --rule='x.invalid/*=y:80' --dry-run=server
kubectl create --dry-run=server -f - <<'Y'
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata: {name: test, namespace: headlamp}
spec:
  routes: [{match: Host(`x.invalid`), kind: Rule, services: [{name: headlamp, port: 80}]}]
Y
```

## Wer eine Adresse im LAN bekommt

LoadBalancer- und NodePort-Services bedient Cilium in eBPF, an Talos'
Ingress-Firewall vorbei. `ServiceExposure.yaml` lässt deshalb nur zu:

- **LoadBalancer** in `traefik-internal` und `traefik-public`, mit
  `allocateLoadBalancerNodePorts: false` und ohne vergebene NodePorts. Das
  Flag wirkt nur beim Anlegen; nachträglich gesetzt, blieben die NodePorts
  stehen - die zweite Regel fängt das beim nächsten Update.
- **NodePort** nur `flux-system/flux-operator-nodeport` (Flux-Statusseite).

Für einen Test mit eigenem LoadBalancer (L2-Gegenprobe) das Binding kurz auf
`Warn` stellen:

```bash
kubectl patch validatingadmissionpolicybinding service-freigabe --type=merge -p '{"spec":{"validationActions":["Warn"]}}'
# ... Test ...
kubectl patch validatingadmissionpolicybinding service-freigabe --type=merge -p '{"spec":{"validationActions":["Deny"]}}'
```

Flux setzt es spätestens beim nächsten Abgleich ohnehin zurück.
