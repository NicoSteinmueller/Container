# core

Der Boden, auf dem alle Gruppen stehen - und die einzige, auf die alle warten.

| Komponente                                           | Was                                                                          |
|------------------------------------------------------|------------------------------------------------------------------------------|
| [`namespaces/`](namespaces/Restricted.yaml)          | alle Namespaces mit Pod-Security-Stufe: `Restricted.yaml`, `Privileged.yaml` |
| [`DefaultDenyIngress.yaml`](DefaultDenyIngress.yaml) | eingehend zu für jeden Pod außer in `kube-system`, `flux-system`             |
| [`DefaultDenyEgress.yaml`](DefaultDenyEgress.yaml)   | ausgehend zu bis auf DNS für `**.cluster.local`                              |
| [`FluxSystemDns.yaml`](FluxSystemDns.yaml)           | DNS-Allowlist für `flux-system` (Git- und Helm-Quellen)                      |
| [`DnsAllowlist.yaml`](DnsAllowlist.yaml)             | keine Freigabe auf Port 53 ohne Namensliste                                  |
| [`NoIngressObjects.yaml`](NoIngressObjects.yaml)     | kein Ingress und keine IngressRoute                                          |
| [`ServiceExposure.yaml`](ServiceExposure.yaml)       | LoadBalancer nur für die Ingress-Controller                                  |
