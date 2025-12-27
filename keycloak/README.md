# Keycloak Setup für Portainer + Nginx Proxy Manager

## Übersicht

Dieses Setup bietet eine minimale Keycloak-Installation mit PostgreSQL-Datenbank, optimiert für:
- **Portainer**: Deployment via Stacks
- **Nginx Proxy Manager**: Reverse Proxy mit SSL

## Deployment in Portainer

1. Gehe zu **Stacks** → **Add Stack**
2. Gib einen Namen ein (z.B. `keycloak`)
3. Füge den Inhalt der `docker-compose.yml` ein
4. Scrolle zu **Environment variables** und setze:

| Variable | Default | Beschreibung |
|----------|---------|-------------|
| `KEYCLOAK_ADMIN_USER` | `admin` | Admin-Benutzername |
| `KEYCLOAK_ADMIN_PASSWORD` | `changeme` | Admin-Passwort ⚠️ **Ändern!** |
| `DB_PASSWORD` | `changeme` | Datenbank-Passwort ⚠️ **Ändern!** |
| `KEYCLOAK_PORT` | `8080` | Externer Port |

5. Klicke auf **Deploy the stack**

## Nginx Proxy Manager Konfiguration

### Proxy Host erstellen

1. Gehe zu **Hosts** → **Proxy Hosts** → **Add Proxy Host**
2. Konfiguriere:

| Feld | Wert |
|------|------|
| Domain Names | `keycloak.deine-domain.de` |
| Scheme | `http` |
| Forward Hostname/IP | `keycloak` (Container-Name) oder IP des Hosts |
| Forward Port | `8080` |
| Websockets Support | ✅ Aktiviert |

3. SSL Tab:
   - **SSL Certificate**: Let's Encrypt anfordern
   - **Force SSL**: ✅ Aktiviert
   - **HTTP/2 Support**: ✅ Aktiviert

### Wichtige Custom Locations / Advanced Config

Falls Probleme auftreten, füge unter **Advanced** folgendes hinzu:

```nginx
proxy_buffer_size 128k;
proxy_buffers 4 256k;
proxy_busy_buffers_size 256k;
```

## Netzwerk-Konfiguration

### Option A: Gleiche Docker-Bridge (empfohlen)

Falls Nginx Proxy Manager im selben Docker-Netzwerk läuft:

1. Füge das externe Netzwerk zur `docker-compose.yml` hinzu:

```yaml
networks:
  keycloak-network:
    driver: bridge
  npm-network:
    external: true
    name: nginx-proxy-manager_default  # Name des NPM-Netzwerks

services:
  keycloak:
    networks:
      - keycloak-network
      - npm-network
```

2. In NPM: Verwende `keycloak` als Forward Hostname

### Option B: Host-Netzwerk

Falls NPM und Keycloak auf unterschiedlichen Hosts laufen:
- Verwende die IP-Adresse des Keycloak-Hosts als Forward Hostname

## Erster Login

1. Öffne `https://keycloak.deine-domain.de`
2. Klicke auf **Administration Console**
3. Login mit:
   - Username: `admin`
   - Password: (das von dir gesetzte Passwort)

## Keycloak für Anwendungen konfigurieren

### Neuen Realm erstellen

1. Klicke auf das Dropdown oben links (zeigt "master")
2. Klicke **Create Realm**
3. Gib einen Namen ein (z.B. `mein-realm`)

### Client für eine Anwendung erstellen

1. Gehe zu **Clients** → **Create client**
2. Konfiguriere:
   - Client ID: z.B. `nextcloud`
   - Client Protocol: `openid-connect`
3. Capability config:
   - Client authentication: ✅ (für vertrauliche Clients)
   - Authorization: Optional
4. Login settings:
   - Root URL: `https://deine-app.domain.de`
   - Valid redirect URIs: `https://deine-app.domain.de/*`

### Benutzer erstellen

1. Gehe zu **Users** → **Add user**
2. Fülle die Felder aus
3. Gehe zu **Credentials** Tab
4. Setze ein Passwort

## Umgebungsvariablen Referenz

### Konfigurierbare Variablen (mit Defaults)

| Variable | Default | Beschreibung |
|----------|---------|-------------|
| `KEYCLOAK_ADMIN_USER` | `admin` | Admin-Benutzername |
| `KEYCLOAK_ADMIN_PASSWORD` | `changeme` | Admin-Passwort |
| `DB_PASSWORD` | `changeme` | Datenbank-Passwort (für Keycloak & PostgreSQL) |
| `KEYCLOAK_PORT` | `8080` | Externer Port für Keycloak |

### Interne Keycloak-Variablen (fest konfiguriert)

| Variable | Wert | Beschreibung |
|----------|------|-------------|
| `KC_PROXY_HEADERS` | `xforwarded` | Proxy-Header-Modus für NPM |
| `KC_HTTP_ENABLED` | `true` | HTTP aktivieren (NPM terminiert SSL) |
| `KC_HOSTNAME_STRICT` | `false` | Strikte Hostname-Prüfung deaktivieren |
| `KC_DB` | `postgres` | Datenbanktyp |
| `KC_DB_URL` | `jdbc:postgresql://keycloak-db:5432/keycloak` | JDBC-URL |
| `KC_DB_USERNAME` | `keycloak` | DB-Benutzer |

## Sicherheitshinweise

⚠️ **Für Produktivbetrieb:**
- Ändere alle Standard-Passwörter
- Verwende starke, zufällige Passwörter
- Aktiviere 2FA für Admin-Accounts
- Überwache die Logs regelmäßig

## Backup & Restore

### Option 1: PostgreSQL Datenbank-Dump (empfohlen)

**Backup erstellen:**
```bash
docker exec keycloak-db pg_dump -U keycloak keycloak > keycloak_backup_$(date +%Y%m%d_%H%M%S).sql
```

**Backup wiederherstellen:**
```bash
# Keycloak stoppen
docker stop keycloak

# Datenbank wiederherstellen
cat keycloak_backup_XXXXXXXX_XXXXXX.sql | docker exec -i keycloak-db psql -U keycloak keycloak

# Keycloak starten
docker start keycloak
```

### Option 2: Realm-Export (für Konfiguration)

Exportiert nur die Realm-Konfiguration (Clients, Rollen, etc.), **keine Benutzer-Passwörter**:

```bash
docker exec keycloak /opt/keycloak/bin/kc.sh export \
  --dir /opt/keycloak/data/export \
  --realm mein-realm
```

Danach die Dateien aus dem Container kopieren:
```bash
docker cp keycloak:/opt/keycloak/data/export ./keycloak-export
```

### Option 3: Docker Volume Backup

**Backup des PostgreSQL-Volumes:**
```bash
# Volume-Name herausfinden
docker volume ls | grep keycloak

# Backup erstellen
docker run --rm \
  -v keycloak_keycloak-db-data:/data \
  -v $(pwd):/backup \
  alpine tar czf /backup/keycloak-db-volume_$(date +%Y%m%d).tar.gz -C /data .
```

**Volume wiederherstellen:**
```bash
docker run --rm \
  -v keycloak_keycloak-db-data:/data \
  -v $(pwd):/backup \
  alpine sh -c "rm -rf /data/* && tar xzf /backup/keycloak-db-volume_XXXXXXXX.tar.gz -C /data"
```

### Automatisches Backup (Cron)

Erstelle ein Backup-Skript `/opt/scripts/keycloak-backup.sh`:

```bash
#!/bin/bash
BACKUP_DIR="/opt/backups/keycloak"
RETENTION_DAYS=7

mkdir -p $BACKUP_DIR
docker exec keycloak-db pg_dump -U keycloak keycloak | gzip > "$BACKUP_DIR/keycloak_$(date +%Y%m%d_%H%M%S).sql.gz"

# Alte Backups löschen
find $BACKUP_DIR -name "keycloak_*.sql.gz" -mtime +$RETENTION_DAYS -delete
```

Cronjob einrichten (täglich um 3:00 Uhr):
```bash
echo "0 3 * * * /opt/scripts/keycloak-backup.sh" | sudo tee -a /etc/crontab
```

