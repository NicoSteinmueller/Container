# core

Der Boden, auf dem alle anderen Gruppen stehen — und deshalb die einzige, auf
die alle warten ([`../sync/core.yaml`](../sync/core.yaml)).

| Datei | Inhalt |
|---|---|
| [`namespaces.yaml`](namespaces.yaml) | alle Namespaces des Clusters mit ihrer Pod-Security-Stufe |
| [`public-ingress-policy.yaml`](public-ingress-policy.yaml) | `ValidatingAdmissionPolicy`: `ingressClassName: public` nur in Namespaces mit `homelab.io/zone=public` |

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
die Begründung steht im Kopf von [`namespaces.yaml`](namespaces.yaml).

## Warum alle Namespaces hier liegen

Damit keine Gruppe auf eine andere warten muss. Die RoleBindings für Traefik
liegen in `monitoring` und `headlamp`, die Egress-Policies bei ihren
Komponenten — lägen die Namespaces jeweils bei der Komponente, hinge `network`
an `observability` und `apps`. So hängt alles an `core` und sonst nichts
aneinander.

Ausnahme ist `whoami`: Den legt das lokale Chart an, Helm besitzt ihn.

## Die zweite Sperre gegen „versehentlich öffentlich"

Ohne `public-ingress-policy.yaml` gäbe es genau eine: die Namespace-Liste in
[`../network/ingress-public.yaml`](../network/ingress-public.yaml). Ein
Namespace zu viel darin, und ein interner Dienst hängt am öffentlichen
Controller. Mit der Policy müssen es zwei Fehler gleichzeitig sein — der Eintrag
in der Liste **und** das Label am Namespace —, und beide stehen in Git.

Nativ und nicht Kyverno: dieselbe Bedingung in derselben Sprache (CEL), nur ohne
Pod, CRD, Webhook und zweiten Controller. Der API-Server wertet sie selbst aus.

```bash
# Beweisfall - erwartet: Ablehnung
kubectl -n headlamp create ingress test --class=public --rule='x.invalid/*=y:80'
```
