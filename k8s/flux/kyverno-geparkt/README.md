# Kyverno — ausgebaut, nicht verworfen

Dieses Verzeichnis liegt in **keinem** Sync-Pfad. Nichts hier wird angewendet;
die Dateien stehen hier, damit die Arbeit und die Begründungen darin nicht
verloren gehen.

## Was passiert ist

Kyverno 1.19 (Chart 3.9.0) lief am 04.09.2026 rund 40 Minuten auf
`talos-cp1` und hat den Cluster in einen Flap-Zyklus gebracht. Die Regel
selbst war dabei nicht das Problem — sie war korrekt, ihr Webhook traf exakt
nur Ingresses, und `kustomization/kyverno-policies` stand auf `Ready`.

Das Problem war das, was das Chart daneben mitbringt:

| | vorher | mit Kyverno |
|---|---|---|
| CRDs im Cluster | 52 | 72 (**+20**) |
| `kube-apiserver` RSS | — | 1108 Mi |
| etcd Health-Check | 264 h ohne Ausfall | zwei Ausfälle in 20 min |

Die Kette: etcd stockt (`Health check failed: context deadline exceeded`) →
API-Server antwortet nicht → alle Leader-Leases und Liveness-Probes laufen
gleichzeitig ins Timeout → Restart-Sturm über den ganzen Cluster
(kube-scheduler, kube-controller-manager, cilium-operator, die
Flux-Controller, traefik-internal) → mehr Last auf etcd. Der Cluster kam
zwischendurch auf 24 von 25 Pods `Ready` und kippte dann wieder.

Auch rein lokale Liveness-Probes (`127.0.0.1:9879`, `localhost:19809`)
liefen in `context deadline exceeded` — es stallte der Node, nicht nur der
API-Server.

Kyvernos eigener Pod war unschuldig: 68 Mi, 17–38 m CPU, wie geplant. Teuer
waren die 20 CRDs — der API-Server muss für jede OpenAPI v2/v3 aufbauen und
ausliefern, und der Admission-Controller öffnet für jede Policy-Art einen
eigenen Watch mit Cache-Sync gegen etcd: `MutatingPolicy`,
`ImageValidatingPolicy`, `NamespacedValidatingPolicy` und so weiter — für
eine einzige `ValidatingPolicy`, die es tatsächlich gibt.

## Wenn es zurückkommen soll

Das Chart kann die CRDs einzeln abwählen. `crds.groups` würde aus 20 CRDs
zwei machen:

```yaml
crds:
  install: true
  groups:
    kyverno:      { cleanuppolicies: false, clustercleanuppolicies: false,
                    clusterpolicies: false, globalcontextentries: false,
                    policies: false, policyexceptions: false,
                    updaterequests: false }
    policies:     { validatingpolicies: true, policyexceptions: false,
                    imagevalidatingpolicies: false,
                    namespacedimagevalidatingpolicies: false,
                    mutatingpolicies: false, namespacedmutatingpolicies: false,
                    generatingpolicies: false, deletingpolicies: false,
                    namespaceddeletingpolicies: false,
                    namespacedvalidatingpolicies: false }
    reports:      { clusterephemeralreports: false, ephemeralreports: false }
    wgpolicyk8s:  { clusterpolicyreports: false, policyreports: false }
  migration:
    enabled: false
```

Ungeprüft ist, ob der Admission-Controller ohne die übrigen CRDs sauber
startet — er legt beim Start Controller für jede Policy-Art an. Das gehört
auf einen Cluster, an dem nichts hängt, nicht auf diesen.

Die ehrlichere Frage steht aber davor: Ob ein Node mit 4 GB, der laut
INBETRIEBNAHME.md noch Immich und Nextcloud aufnehmen soll, sich einen
zweiten Admission-Controller leisten kann. Die Alternative zu Kyverno ist
eine native `ValidatingAdmissionPolicy` — dieselbe CEL-Bedingung, die in
`public-ingress.yaml` schon steht, direkt vom API-Server durchgesetzt, ohne
Pod, ohne CRDs, ohne Webhook-Roundtrip. Seit Kubernetes 1.30 ist die API
stabil, und der Cluster läuft auf 1.36.

## Dateien

- `kyverno.yaml` — HelmRepository, Namespace, HelmRelease, und die zweite
  Flux-Kustomization für die Regel. Der Kopf der Datei erklärt, warum die
  Regel getrennt liegen muss (CRD-Henne-Ei beim Server-Side-Dry-Run).
- `public-ingress.yaml` — die `ValidatingPolicy` mit der CEL-Bedingung und
  ihrer Begründung. Der Inhalt ist unabhängig von Kyverno brauchbar: Die
  Bedingung lässt sich unverändert in eine native
  `ValidatingAdmissionPolicy` übernehmen.
