# homepage

Startseite unter `https://k8s.nico-steinmueller.de`, nur aus dem Heimnetz
über `ingress-internal`. Listet die Dienste mit Link, Pod-Status und
Auslastung ([Homepage](https://gethomepage.dev)).

**Die Liste pflegt sich nicht selbst.** Homepage findet Dienste nur über
Ingress-, IngressRoute- oder HTTPRoute-Objekte, und die gibt es hier nicht -
die Routen stehen im File-Provider von Traefik. Ein neuer Dienst braucht also
neben den drei Handgriffen aus
[`ingress-internal`](../../network/ingress-internal/README.md) einen Eintrag
in `services.yaml` ([`Config.yaml`](Config.yaml)).

Der Status kommt aus der Kubernetes-API, nicht vom Dienst selbst: `running`
heißt, alle passenden Pods laufen - nicht, dass die Route funktioniert.

**GPU:** Die Karte liest Prometheus, nicht die API - Auslastung und VRAM
aus dem `drm`-Collector von node-exporter, Temperatur und Leistung aus hwmon
(Chip `amdgpu`).
