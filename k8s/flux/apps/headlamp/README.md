# headlamp

Nur über `traefik-internal` erreichbar - das Token beim Login soll nicht im
Klartext durchs LAN. RBAC eigen in `RBAC.yaml`, weil das Chart ab Werk an
`cluster-admin` bindet:

| ServiceAccount | Rechte |
|---|---|
| `headlamp` | Pod und Lese-Token. Kein Schreiben, keine Secrets. |
| `headlamp-admin` | `cluster-admin`, ohne Pod und Token - bei Bedarf eines für eine Stunde. |

```bash
kubectl -n headlamp create token headlamp --duration=8h        # Lesen
kubectl -n headlamp create token headlamp-admin --duration=1h  # Ändern
```
