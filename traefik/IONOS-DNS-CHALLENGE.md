# IONOS DNS Challenge Einrichtung für Traefik

## Voraussetzungen

Um die DNS Challenge mit IONOS zu nutzen, benötigen Sie einen IONOS API Key mit DNS-Berechtigung.

## Schritt-für-Schritt Anleitung

### 1. IONOS API Key erstellen

1. Gehen Sie zu: https://developer.hosting.ionos.de/keys
2. Loggen Sie sich mit Ihren IONOS-Zugangsdaten ein
3. Klicken Sie auf "Neuen API-Schlüssel erstellen"
4. **Wichtig:** Wählen Sie die Berechtigung **"DNS"** aus
5. Notieren Sie sich den API Key (wird nur einmal angezeigt!)

### 2. API Key in .env Datei speichern

Erstellen Sie eine `.env` Datei im `traefik/` Verzeichnis:

```bash
# Im traefik Verzeichnis
cp .env.example .env
```

Öffnen Sie die `.env` Datei und tragen Sie Ihren API Key ein:

```env
IONOS_API_KEY=ihr_echter_ionos_api_key_hier
```

**Wichtig:** Die `.env` Datei sollte NICHT in Git committed werden (ist bereits in .gitignore).

### 3. Traefik Container neu starten

```bash
cd C:\Entwicklung\Container\traefik
docker-compose down
docker-compose up -d
```

### 4. DNS-Einträge bei IONOS erstellen

Für jeden Service müssen Sie A-Records bei IONOS anlegen:

**Öffentliche Services:**
```
cloud.ihre-domain.de    A    <Ihre öffentliche IP>
```

**Lokale Services:**
```
photos.ihre-domain.de   A    <Ihre öffentliche IP>
# ODER falls nur lokal verwendet:
photos.ihre-domain.de   A    <Ihre lokale Server-IP>
```

**Wichtig:** Auch für rein lokale Services muss der DNS-Eintrag bei IONOS existieren, damit die DNS Challenge funktioniert!

### 5. Testen

Prüfen Sie die Traefik Logs:

```bash
docker logs traefik
```

Achten Sie auf Meldungen wie:
- `Obtaining certificate...`
- `Certificate obtained successfully`

Bei Fehlern:
- `Unable to obtain ACME certificate` → Prüfen Sie API Key und DNS-Einträge
- `Error checking DNS propagation` → Warten Sie 1-2 Minuten und versuchen Sie es erneut

## Vorteile der DNS Challenge mit IONOS

✅ **Wildcard-Zertifikate möglich**
   - `*.ihre-domain.de` für alle Subdomains

✅ **Zertifikate für nicht-öffentliche Services**
   - Services die nur im lokalen Netzwerk erreichbar sind

✅ **Port 80 muss nicht öffentlich sein**
   - Funktioniert auch hinter NAT/Firewall

✅ **Kein Traffic über Port 80**
   - Sicherer als HTTP Challenge

## Beispiel-Konfiguration für Services

### Öffentlicher Service (z.B. Nextcloud)

```yaml
services:
  nextcloud:
    image: nextcloud:latest
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.nextcloud.rule=Host(`cloud.ihre-domain.de`)"
      - "traefik.http.routers.nextcloud.entrypoints=websecure"
      - "traefik.http.routers.nextcloud.tls.certresolver=letsencrypt"
      - "traefik.http.services.nextcloud.loadbalancer.server.port=80"
    networks:
      - proxy
```

### Lokaler Service (z.B. Immich)

```yaml
services:
  immich-server:
    image: ghcr.io/immich-app/immich-server:latest
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.immich.rule=Host(`photos.ihre-domain.de`)"
      - "traefik.http.routers.immich.entrypoints=websecure"
      - "traefik.http.routers.immich.tls.certresolver=letsencrypt"
      - "traefik.http.routers.immich.middlewares=local-only@file"
      - "traefik.http.services.immich.loadbalancer.server.port=2283"
    networks:
      - proxy
```

### Wildcard-Zertifikat

Wenn Sie ein Wildcard-Zertifikat nutzen möchten, erstellen Sie einen DNS-Eintrag:

```
*.local.ihre-domain.de   A    <Ihre IP>
```

Service-Labels:
```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.service1.rule=Host(`service1.local.ihre-domain.de`)"
  - "traefik.http.routers.service1.entrypoints=websecure"
  - "traefik.http.routers.service1.tls.certresolver=letsencrypt"
  - "traefik.http.routers.service1.tls.domains[0].main=local.ihre-domain.de"
  - "traefik.http.routers.service1.tls.domains[0].sans=*.local.ihre-domain.de"
```

## Troubleshooting

### API Key wird nicht erkannt

**Problem:** `Error getting IONOS API credentials`

**Lösung:**
1. Prüfen Sie die `.env` Datei
2. Stellen Sie sicher, dass docker-compose die Datei lädt
3. Prüfen Sie die Umgebungsvariable im Container:
   ```bash
   docker exec traefik env | grep IONOS
   ```

### DNS-Propagation Fehler

**Problem:** `Timeout during DNS verification`

**Lösung:**
1. Erhöhen Sie `delayBeforeCheck` in traefik.yml:
   ```yaml
   delayBeforeCheck: "60"  # 60 Sekunden warten
   ```
2. Prüfen Sie DNS-Auflösung:
   ```bash
   nslookup ihre-domain.de 1.1.1.1
   ```

### Rate Limit von Let's Encrypt

**Problem:** `Too many certificates already issued`

**Lösung:**
1. Nutzen Sie zunächst den Staging Server (bereits konfiguriert)
2. Warten Sie 1 Woche (Let's Encrypt Limit: 50 Zertifikate pro Woche)
3. Nutzen Sie Wildcard-Zertifikate für mehrere Subdomains

### Berechtigungen fehlen

**Problem:** `IONOS API returned 403 Forbidden`

**Lösung:**
1. Erstellen Sie einen neuen API Key
2. Stellen Sie sicher, dass die **DNS-Berechtigung** aktiviert ist
3. Tragen Sie den neuen Key in die `.env` Datei ein
4. Starten Sie Traefik neu

## Wechsel zu Produktiv-Server

Sobald alles funktioniert, wechseln Sie in `traefik/config/traefik.yml`:

```yaml
certificatesResolvers:
  letsencrypt:
    acme:
      # Auskommentieren:
      # caServer: https://acme-staging-v02.api.letsencrypt.org/directory
      # Einkommentieren:
      caServer: https://acme-v02.api.letsencrypt.org/directory
```

**Wichtig:** Löschen Sie vorher die Staging-Zertifikate:

```bash
docker exec traefik rm /letsencrypt/acme.json
docker-compose restart
```

## Sicherheitshinweise

⚠️ **API Key schützen:**
- Niemals in Git committen
- `.env` Datei ist in `.gitignore`
- Nur minimale Berechtigungen (nur DNS)
- Bei Kompromittierung sofort neuen Key erstellen

⚠️ **Backup:**
```bash
# Zertifikate sichern
docker cp traefik:/letsencrypt/acme.json ./backup/acme.json.backup
```

## Weiterführende Links

- [IONOS Developer Portal](https://developer.hosting.ionos.de/)
- [Traefik IONOS DNS Provider Dokumentation](https://doc.traefik.io/traefik/https/acme/#providers)
- [Let's Encrypt Rate Limits](https://letsencrypt.org/docs/rate-limits/)

