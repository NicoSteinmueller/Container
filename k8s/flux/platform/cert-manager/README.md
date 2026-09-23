# cert-manager

Nur die **interne** CA - öffentliche Zertifikate holt Traefik selbst per
DNS-01. Deshalb kein DNS-Provider-Token und keine CA, der ein Browser traut.

**Anlass ist CrowdSec:** Der Agent registriert sich mit seinem Pod-Namen bei der
LAPI. Startet der Container ohne neuen Pod neu, hängt der Init-Container für
immer an `403 … user already exist`. Mit `tls.enabled` weist sich der Agent per
Client-Zertifikat aus, und die Registrierung entfällt.

Issuer und Zertifikate liegen in
[`../../cert-manager-issuers`](../../cert-manager-issuers), weil ihre CRDs erst
mit dieser Release entstehen.
