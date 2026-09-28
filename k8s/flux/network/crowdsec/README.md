# crowdsec

Der **Agent** liest die Zugriffslogs von `ingress-public` und meldet Treffer an
die **LAPI**. Der **Bouncer** sitzt als Plugin im Traefik von `ingress-public`
und fragt die LAPI vor jeder Anfrage.

