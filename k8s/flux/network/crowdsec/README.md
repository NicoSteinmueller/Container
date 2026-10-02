# crowdsec

Der **Agent** liest die Zugriffslogs von `ingress-public` und meldet Treffer an
die **LAPI**. Der **Bouncer** sitzt als Plugin im Traefik von `ingress-public`
und fragt die LAPI vor jeder Anfrage.

**AppSec** ist der dritte Teil: ein eigener Pod (`crowdsec-appsec`), an den
der Bouncer jede Anfrage samt den ersten 10 MB Body schickt, bevor sie
weitergeht.

| appsec-config                  | Was                                                   | Wirkung                        |
|--------------------------------|-------------------------------------------------------|--------------------------------|
| `crowdsecurity/appsec-default` | Virtual Patching bekannter CVEs, generische Regeln    | blockt die Anfrage             |
| `crowdsecurity/crs`            | OWASP Core Rule Set, mit Nextcloud-Exclusion          | Alarm; wiederholt: Bann der IP |
