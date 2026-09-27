# cert-manager

Nur die **interne** CA.

**Anlass ist CrowdSec:** Der Agent registriert sich mit seinem Pod-Namen bei der
LAPI. Startet der Container ohne neuen Pod neu, hängt der Init-Container für
immer an `403 … user already exist`. Mit `tls.enabled` weist sich der Agent per
Client-Zertifikat aus, und die Registrierung entfällt.
