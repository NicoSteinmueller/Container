# ingress-public

Traefik fürs Internet auf `192.168.178.232`, gebaut wie
[`ingress-internal`](../ingress-internal/README.md) - mit diesen Unterschieden:

- **Kette am Entrypoint** `websecure` (`public-chain`): CrowdSec-Bouncer,
  Security-Header, Ratelimit. Am Entrypoint, damit kein Ingress sie vergessen
  kann.
- **Zertifikat je Router** statt Wildcard; öffentliche Namen stehen ohnehin im
  DNS.
- **`externalTrafficPolicy: Local`**, sonst sähe CrowdSec alle Clients unter der
  Node-Adresse.
- **`forwardedHeaders.trustedIPs: []`**: Kein Proxy davor, also überschreibt
  Traefik `X-Forwarded-*`, statt sie zu übernehmen.
- **`TLSOption` mit `sniStrict`**: Unbekannte Namen enden im Handshake.
- **Kein Kubernetes-Provider, kein Token.** Routen, Middlewares und die
  TLS-Option stehen in [`DynamicConfig.yaml`](DynamicConfig.yaml) (File-Provider).
  Ein Kubernetes-Provider startete je Namespace einen Secrets-Informer - der
  exponierteste Pod läse dann in jedem Dienst-Namespace alles, auch den
  DB-Zugang. So hat er keine Rechte, kein Token (`postRenderer` in
  `HelmRelease.yaml`, das Chart setzt es sonst fest) und keinen Weg zur API.
- **Ein öffentlicher Dienst** braucht drei Einträge: Router und Service in
  `routes.yaml` (Service per `http://<svc>.<ns>.svc.cluster.local`), einen
  `toEndpoints`-Block in `NetworkPolicies.yaml` und im Ziel-Namespace eine
  Policy, die `traefik-public` hereinlässt. Ein Ingress-Objekt
  lehnt der Cluster ab ([`../../core/NoIngressObjects.yaml`](../../core/NoIngressObjects.yaml)).
- **Eine Änderung an `DynamicConfig.yaml`** startet den Controller über
  Reloader neu (`Recreate`, kurze Unterbrechung).

> **Stand:** whoami ist der einzige Dienst. Immich und Nextcloud laufen noch auf
> dem Unraid-Host. AppSec kommt mit dem ersten Dienst, den eine WAF-Regel schützen
> soll; die Fritzbox-Freigabe zuletzt.
