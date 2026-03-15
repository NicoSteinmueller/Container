# Nextcloud Docker Setup

Dateiberechtigungen müssen auf 33 liegen
# www-data hat UID 33 im Nextcloud-Container
sudo chown -R 33:33 /mnt/user/data/nextcloud/data
sudo chmod -R 0770 /mnt/user/data/nextcloud/data

# Log-Datei ebenfalls
sudo chown 33:33 /mnt/user/logs/nextcloud/nextcloud.log



## Beschreibung
Dieses Setup enthält eine vollständige Nextcloud-Installation mit:
- **Nextcloud** (Apache-basiert)
- **PostgreSQL** als Datenbank
- **Redis** für Caching und Session-Verwaltung
- **Cron-Service** für Hintergrundaufgaben

## Port
- Nextcloud: **38080** (HTTP)

## Umgebungsvariablen

### Datenbank
- `POSTGRES_PASSWORD`: Datenbank-Passwort (Standard: changeme)

### Nextcloud Admin
- `NEXTCLOUD_ADMIN_USER`: Admin-Benutzername (Standard: admin)
- `NEXTCLOUD_ADMIN_PASSWORD`: Admin-Passwort (Standard: changeme)

### Netzwerk
- `NEXTCLOUD_TRUSTED_DOMAINS`: Vertrauenswürdige Domains, kommagetrennt (Standard: localhost)

### Redis
- `REDIS_PASSWORD`: Redis-Passwort (Standard: changeme)

## Erste Schritte

1. **Umgebungsvariablen setzen** (optional):
   - In Portainer oder in einer `.env`-Datei
   - Mindestens `POSTGRES_PASSWORD` und `NEXTCLOUD_ADMIN_PASSWORD` ändern!

2. **Container starten**:
   ```bash
   docker-compose up -d
   ```

3. **Nextcloud aufrufen**:
   - URL: `http://localhost:38080`
   - oder `http://[SERVER-IP]:38080`

4. **Erster Login**:
   - Benutzername: Wert von `NEXTCLOUD_ADMIN_USER` (Standard: admin)
   - Passwort: Wert von `NEXTCLOUD_ADMIN_PASSWORD`

## Volumes

- `nextcloud-data`: Hauptdaten und Dateien
- `nextcloud-config`: Konfigurationsdateien
- `nextcloud-apps`: Custom Apps
- `nextcloud-theme`: Themes
- `database-data`: PostgreSQL-Daten

## Hinter Reverse Proxy (Traefik/Nginx)

Wenn Nextcloud hinter einem Reverse Proxy läuft:

1. Setze `NEXTCLOUD_TRUSTED_DOMAINS` auf deine Domain(s)
2. Die Umgebungsvariablen `OVERWRITEPROTOCOL` und `OVERWRITECLIURL` sind bereits konfiguriert
3. Stelle sicher, dass der Proxy die Header `X-Forwarded-For`, `X-Forwarded-Proto` und `X-Forwarded-Host` setzt

## Performance-Tipps

1. **Memory Cache** ist über Redis bereits aktiviert
2. **APCu** für lokales Caching (bereits in der Apache-Version enthalten)
3. **Cron-Jobs** werden über den separaten Cron-Container ausgeführt

## Backup

Wichtige Verzeichnisse zum Sichern:
- `nextcloud-data` - Alle Benutzerdaten
- `nextcloud-config` - Konfiguration
- `database-data` - Datenbank

## Wartung

### Container-Logs anzeigen
```bash
docker-compose logs -f nextcloud
```

### In Container zugreifen
```bash
docker exec -it nextcloud bash
```

### OCC-Befehle ausführen
```bash
docker exec -it -u www-data nextcloud php occ <befehl>
```

Beispiele:
```bash
# Status anzeigen
docker exec -it -u www-data nextcloud php occ status

# Dateien scannen
docker exec -it -u www-data nextcloud php occ files:scan --all

# Wartungsmodus ein/aus
docker exec -it -u www-data nextcloud php occ maintenance:mode --on
docker exec -it -u www-data nextcloud php occ maintenance:mode --off
```

## Update

1. Backup erstellen!
2. Image-Version in `docker-compose.yml` anpassen
3. Container neu starten:
   ```bash
   docker-compose pull
   docker-compose up -d
   ```
4. Nextcloud führt automatisch Datenbank-Migrations durch

## Troubleshooting

### Verbindungsprobleme
- Überprüfe, ob alle Container laufen: `docker-compose ps`
- Prüfe Logs: `docker-compose logs`

### "Untrusted Domain" Fehler
- Füge deine Domain zu `NEXTCLOUD_TRUSTED_DOMAINS` hinzu
- Oder manuell in der `config/config.php` editieren

### Performance-Probleme
- Erhöhe PHP Memory Limit
- Aktiviere weitere Caching-Mechanismen
- Nutze NGINX statt Apache (FPM-Version)

## Sicherheit

⚠️ **Wichtig**: Ändere vor dem produktiven Einsatz:
- `POSTGRES_PASSWORD`
- `NEXTCLOUD_ADMIN_PASSWORD`
- `REDIS_PASSWORD`

Verwende sichere, zufällige Passwörter!
