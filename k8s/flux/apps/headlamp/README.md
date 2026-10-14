# headlamp

Anmeldung über Keycloak. Headlamp
reicht das ID-Token an die API weiter; die prüft es selbst, eingerichtet in
[`KubeAuthenticationConfig`](../../../../vm/talos/patches/cluster.yaml.tftpl).
Benutzer heißen dort `oidc:<preferred_username>`, die Realm-Rollen werden zu
Gruppen `oidc:<rolle>`

| Wer | Rechte |
|---|---|
| Realm-Rolle `admin` | `cluster-admin`, Lesen und Schreiben. |
| Realm-Rolle `user` | Lesen. Kein Schreiben, keine Secrets. |
| ServiceAccount `headlamp` | dieselben, als Token. |
| ServiceAccount `headlamp-admin` | `cluster-admin`, ohne Pod und Token - bei Bedarf eines für eine Stunde. |

```bash
kubectl -n headlamp create token headlamp --duration=8h        # Lesen
kubectl -n headlamp create token headlamp-admin --duration=1h  # Ändern
```

## Keycloak

Der Client steht in der Datenbank, nicht im Manifest. Einmal anlegen, in
der Admin-Konsole unter `mein-realm`:

1. **Clients -> Create client**: Client ID `headlamp`, Client authentication
   an, nur Standard flow. Valid redirect URI
   `https://dashboard.k8s.nico-steinmueller.de/oidc-callback`.
2. **Advanced -> PKCE Method** `S256`.
3. **Client scopes -> headlamp-dedicated -> Configure a new mapper -> User
   Realm Role**: Token Claim Name `realm_access.roles`, Multivalued an, Add to
   ID token an. Keycloak schreibt die Rollen sonst nur ins Access-Token,
   Headlamp schickt aber das ID-Token - ohne den Mapper greift keine Rolle.
4. **Credentials**: Secret nach `homelab-secrets`, Schlüssel
   `OIDC_CLIENT_SECRET` in `cluster/headlamp-oidc.sops.yaml`.

Lehnt die API das Token ab, steht der Grund im Log des apiservers:

```bash
kubectl -n kube-system logs -l component=kube-apiserver --tail=500 | grep -i -E 'jwt|oidc'
```
