# ingress-internal

Traefik fürs Heimnetz auf `192.168.178.231`. Von außen nur aus dem LAN
(`allow-from-lan`, `ipBlock`), an die Anwendungen nur über den Controller.

**Ein neuer Dienst** braucht drei Einträge - fehlt einer, bleibt es still:

- Router und Service in `routes.yaml` (`http://<svc>.<ns>.svc.cluster.local`)
- ein `toEndpoints`-Block in `traefik-internal-egress` (`NetworkPolicies.yaml`)
- im Ziel-Namespace eine Policy, die `traefik-internal` hereinlässt
