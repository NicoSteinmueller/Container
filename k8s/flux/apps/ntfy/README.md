# ntfy

Push-Benachrichtigungen unter `https://ntfy.nico-steinmueller.de`

## Zugang

Benutzer, Rechte und Tokens stehen deklarativ im Secret `ntfy-auth`
(`homelab-secrets`, Schlüssel `NTFY_AUTH_USERS`, `NTFY_AUTH_ACCESS`,
`NTFY_AUTH_TOKENS`) 

ntfy gleicht Benutzer, Rechte und Tokens bei jedem Start mit dem Secret ab.
