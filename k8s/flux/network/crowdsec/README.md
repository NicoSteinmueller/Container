# crowdsec

Der **Agent** liest die Zugriffslogs von `ingress-public` und meldet Treffer an
die **LAPI**. Der **Bouncer** sitzt als Plugin im Traefik von `ingress-public`
und fragt die LAPI vor jeder Anfrage.

Der Agent weist sich per Client-Zertifikat aus, nicht per Passwort - der Grund
steht in [../../platform/cert-manager/README.md](../../platform/cert-manager/README.md).

Bewusst nicht dabei: AppSec, Console-Registrierung, Metabase -
`cscli decisions list` reicht.
