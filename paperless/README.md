# TODO: OCR für scanner deaktivieren?

# Paperless-ngx mit Keycloak SSO

## Architektur-Übersicht
```
┌──────────────────────────────────────────────────┐
│                  Geteilte Services               │
│  ┌──────────────┐              ┌──────────────┐  │
│  │  Gotenberg   │              │     Tika     │  │
│  │ (PDF-Konv.)  │              │    (OCR)     │  │
│  └──────────────┘              └──────────────┘  │
│               paperless_shared Network           │
└──────────────────────────────────────────────────┘
                           ▲
                           │
                           │
        ┌──────────────────┴─────────────────┐
        │                                    │
┌───────▼────────┐                  ┌────────▼────────┐
│  Instanz: main │                  │ Instanz: privat │
│                │                  │                 │
│  Paperless     │                  │  Paperless      │
│  PostgreSQL    │                  │  PostgreSQL     │
│  Redis         │                  │  Redis          │
│                │                  │                 │
│  Port: 61349   │                  │  Port: 61350    │
└────────────────┘                  └─────────────────┘
```
## Deployment
### Geteilte Services
**Stack-Name:** `paperless-shared`  
**Datei:** `docker-compose.shared.yml`

- **Gotenberg**: PDF-Konvertierung
- **Tika**: OCR und Dokumentenanalyse

### Instanzen
**Stack-Name:** `paperless-main`  
**Datei:** `docker-compose.yml`

- **Paperless**: Hauptanwendung
- **PostgreSQL**: Datenbank
- **Redis**: Cache

**<span style="color: red;">Für jede Instanz einen eigenen Keycloak Client anlegen.</span>**

**Environment Variables:**

| Variable | Beispiel                                                                                                                                                                                                                         | Beschreibung                                                                     |
|----------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------|
| `INSTANCE_NAME` | `main`                                                                                                                                                                                                                           | Name der Instanz                                                                 |
|     `INSTANCE_PORT`            | `61349`                                                                                                                                                                                                                          | Externer Port für das Webinterface                                               |
| `DB_PASSWORD`         | `changeme`                                                                                                                                                                                                                       | Postgres Datenbank-Passwort                                                      |
| `PAPERLESS_SECRET_KEY`         | `changeme`                                                                                                                                                                                                                       | Key für Erstellung der Session Tokens (min. 50 Zeichen, AlphaNum + Sonderzeichen) |
| `PAPERLESS_DATA_BASE_PATH`         | `/mnt/paperless`                                                                                                                                                                                                                 | Grundpfad auf dem Host für Daten                                                 |
| `PAPERLESS_URL`         | `https://docs.example.com`                                                                                                                                                                                                       | externe URL                                                         |
| `KEYCLOAK_CONFIG`         | `{"openid_connect":{"APPS":[{"provider_id":"keycloak","name":"Keycloak","client_id":"<CLIENT_ID>","secret":"<CLIENT_SECRET>","settings":{"server_url":"https://<KEYCLOAK_DOMAIN>/realms/<REALM>"}}],"OAUTH_PKCE_ENABLED":true}}` | JSON-Konfig für OpenID Connect Provider                                          |
| `PAPERLESS_ALLOW_SIGNUPS`         | `false`                                                                                                                                                                                                                          | Anlegen von Usern bei ersten SSO-Login                                           |
| `PAPERLESS_DISABLE_REGULAR_LOGIN`         | `true`                                                                                                                                                                                                                           | Standard-Login deaktviert                                                        |
| `PAPERLESS_LOGOUT_REDIRECT_URL`         | `https://<KEYCLOAK_DOMAIN>/realms/<REALM>/protocol/openid-connect/logout?post_logout_redirect_uri=https://<PAPERLESS_DOMAIN>&&client_id=<CLIENT_ID>`                                                                   |                                                                                  |
| `PAPERLESS_IGNORE_DATES`         | `25.04.1985,01.01.2000`                                                                                                                                                                                                                                 | Daten, die bei der automatischen Datumserkennung ignoriert werden sollen                                                                                 |

## erste Konfiguration
- Paperless Instanz im Browser öffnen: `https://<INSTANZ_IP+PORT>/main`
- Tmp-Admin-User anlegen
- Nginx Proxy Manager Proxy Host für die Instanz anlegen (siehe unten)
- mit Keycloak Admin-User anmelden
- mit dem Tmp-Admin-User in Paperless anmelden und Keycloak Admin-User die Superuser-Rechte geben
- mit Keycloak Admin-User in Paperless anmelden und den Tmp-Admin-User löschen
- normalen Login deaktivieren
- mit notwendigen Nutzerkonten einloggen
- Registrierung deaktivieren

# Nginx Proxy Manager
## Architektur
- Alle Instanzen auf einer Domain mit verschiedenen Pfaden
- Beispiel: https://docs.example.com/paperless-main, https://docs.example.com/paperless-privat
- Nur eine Domain und ein SSL-Zertifikat nötig

## Proxy Host Konfiguration
### Details
- Domain Names: `docs.example.com`
- Scheme: `http`
- Forward Hostname / IP: `paperless-main` (bzw. IP-Adresse des Hosts)
- Forward Port: `61349` (bzw. der konfigurierte Port der Instanz)
- Cache Assets: ✓ aktivieren
- Block Common Exploits: ✓ aktivieren
- Websockets Support: ✓ aktivieren

### SSL
- SSL Certificate: `Let's Encrypt`
- Force SSL: ✓ aktivieren
- HTTP/2 Support: ✓ aktivieren
- HSTS Enabled: ✓ aktivieren
- HSTS Subdomains: ✓ aktivieren

### Custom Locations
#### Root Location

- Location: `/`
- Scheme: `http`
- Forward Hostname / IP: `paperless-main` (bzw. IP-Adresse des Hosts)
- Forward Port: `61349` (bzw. der konfigurierte Port der Instanz)

**Advanced**
````nginx configuration
location /admin {
    allow 192.168.178.0/24;
    deny all;

    proxy_pass http://<INSTANZ_IP>:<INSTANZ_PORT>;

    # Proxy Headers
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Port $server_port;

    # Websockets
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";

    # Upload-Größe für Dokumente
    client_max_body_size 100M;

    # Timeouts
    proxy_read_timeout 300;
    proxy_connect_timeout 300;
    proxy_send_timeout 300;
}

location / {
    proxy_pass http://<INSTANZ_IP>:<INSTANZ_PORT>;

    # Proxy Headers
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Port $server_port;

    # Websockets
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";

    # Upload-Größe für Dokumente
    client_max_body_size 100M;

    # Timeouts
    proxy_read_timeout 300;
    proxy_connect_timeout 300;
    proxy_send_timeout 300;
}
````

# Paperless-ngx Administration
## Superuser anlegen
```bash
docker exec -it <PAPERLESS_CONTAINER> createsuperuser
```

## Django Admin Interface
- erreichbar unter: `https://<PAPERLESS_DOMAIN>/admin/`

## Backup
### Dokumente & Datenbank sichern
```bash
document_exporter ../export --use-folder-prefix --zip
```
**Ergebnis:** Zip-Datei (z.b. `export-2026-01-21.zip`) mit allen Dokumenten, Metadaten, Einstellungen und Nutzer

**Backup Skript für alle Instanzen**

````bash
#!/bin/bash
BACKUP_DIR="/mnt/user/paperless/export"
RETENTION_DAYS=10

# Array mit allen Paperless-Instanzen
INSTANCES=("main" "privat")

# Backup für jede Instanz erstellen
for INSTANCE in "${INSTANCES[@]}"; do
  # Export erstellen
  docker exec paperless_$INSTANCE document_exporter ../export --use-folder-prefix --zip
done
# Alte Backups löschen
find $BACKUP_DIR -name "export*.zip" -mtime +$RETENTION_DAYS -delete
````

### Dokumente & Datenbank wiederherstellen
**<span style="color: red;">muss komplett leere Instanz sein (ohne Dokumente und leere Datenbank)</span>**
```bash
document_importer ../export/export-2026-01-21.zip
```

## Änderung an PAPERLESS_FILENAME_FORMAT
alle Dokumente nach dem neuen Schema umbenennen
```bash
document_renamer
```

## Neue Tags / Kategorien / etc. angelegt und für alle Dokumente übernehmen
```bash
document_retagger [-h] [-c] [-T] [-t] [-i] [--id-range] [--use-first] [-f]

optional arguments:
-c, --correspondent
-T, --tags
-t, --document_type
-s, --storage_path
-i, --inbox-only
--id-range
--use-first
-f, --overwrite
```


