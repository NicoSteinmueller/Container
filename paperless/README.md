# Paperless-ngx Container-Setup

Diese Konfiguration folgt dem Standard-Template-Muster und besteht aus drei Compose-Dateien:

- **compose.yml**: Basis-Konfiguration mit allen Services
- **compose.override.yml**: Development-Einstellungen (lokal)
- **compose.prod.yml**: Production-Einstellungen mit Traefik

## Services

- **paperless**: Hauptanwendung
- **database**: PostgreSQL Datenbank
- **redis**: Redis Cache
- **gotenberg**: Dokumenten-Konvertierung (PDF)
- **tika**: Datei-Parsing für OCR

## Development-Betrieb

```bash
# Alle Services starten (lokal, mit localhost)
docker compose up -d

# Services stoppen
docker compose down
```

Zugänglich über: http://localhost:8000

## Production-Betrieb

```bash
# Mit Production-Konfiguration (Traefik, externe Volumes)
docker compose -f compose.yml -f compose.prod.yml up -d

# Environment-Variablen müssen gesetzt sein (siehe .env)
```

## Konfiguration

Erstelle eine `.env` Datei im paperless-Verzeichnis mit folgendem Inhalt:

```bash
INSTANCE_NAME=main
DB_PASSWORD=<sicheres-passwort>
PAPERLESS_SECRET_KEY=<mindestens-50-zeichen-alphanumerisch>
KEYCLOAK_SECRET=<keycloak-client-secret>
PAPERLESS_ALLOW_SIGNUPS=false
PAPERLESS_DISABLE_REGULAR_LOGIN=true
PAPERLESS_IGNORE_DATES=
```

### Erforderliche Umgebungsvariablen

| Variable | Default | Beschreibung |
|----------|---------|-------------|
| `INSTANCE_NAME` | `main` | Eindeutiger Name für mehrere Instanzen |
| `DB_PASSWORD` | `changeme` | PostgreSQL-Passwort |
| `PAPERLESS_SECRET_KEY` | `changeme` | Django Secret Key (50+ Zeichen) |
| `KEYCLOAK_SECRET` | - | Client-Secret für Keycloak OIDC |
| `PAPERLESS_ALLOW_SIGNUPS` | `false` | Auto-Erstellung von Usern bei SSO |
| `PAPERLESS_DISABLE_REGULAR_LOGIN` | `true` | Login-Formular deaktivieren |
| `PAPERLESS_IGNORE_DATES` | - | Komma-getrennte Daten ignorieren |

## Volumes (Development)

```
./data/
  ├── paperless/          # Appdata (Einstellungen)
  ├── media/              # Hochgeladene Dokumente
  ├── export/             # Exportierte Dokumente
  ├── consume/            # Verzeichnis für Datei-Upload
  └── postgres/           # Datenbankdaten
```

## Volumes (Production)

```
/mnt/user/
  ├── appdata/paperless/
  ├── data/paperless/
  └── logs/paperless/
```

## Network

- **Development**: Bridge-Network (automatisch erstellt)
- **Production**: `paperless_${INSTANCE_NAME}_network` + `proxy` (Traefik)

## Traefik-Integration (Production)

Die Anwendung wird automatisch unter `paperless-${INSTANCE_NAME}.nico-steinmueller.de` verfügbar gemacht:

- `/admin` Route: Nur lokal erreichbar (`local-only` Middleware)
- Alle anderen Routes: Öffentlich erreichbar mit CrowdSec-Schutz

## OCR & Verarbeitung

- **Sprachen**: Deutsch + Englisch
- **Workers**: 1 Worker mit 4 Threads
- **Timeout**: 30 Minuten pro Dokument
- **Duplikate**: Werden automatisch gelöscht

## Keycloak SSO

Falls aktiviert, verwendet die Anwendung OpenID Connect (Keycloak) für die Authentifizierung. Der reguläre Login wird deaktiviert.

Konfiguration:
- **Server**: https://keycloak.nico-steinmueller.de/realms/mein-realm
- **Client ID**: `paperless_${INSTANCE_NAME}`
- **Client Secret**: Siehe `.env`

## Mehrere Instanzen

Für mehrere unabhängige Paperless-Instanzen:

1. Separate Verzeichnisse erstellen: `paperless-main/`, `paperless-secondary/`
2. In jedem Verzeichnis: `.env` mit unterschiedlichem `INSTANCE_NAME` setzen
3. Jede Instanz hat eigene Datenbank, Redis, Volumes und Traefik-Route

## Sicherheit

- Alle Container laufen mit `no-new-privileges:true`
- CAP_DROP: ALL (nur notwendige Capabilities werden hinzugefügt)
- Read-only Dateisystem für stateless Services
- tmpfs für temporäre Dateien (noexec, nosuid)

## Health Checks

Alle Services haben Health Checks konfiguriert und werden automatisch neu gestartet bei Fehlern.

Status prüfen:
```bash
docker compose ps
```

## Logging

Die Logs sind auf max 10 MB pro Datei und 3 Dateien begrenzt (json-file Driver).

```bash
# Logs anzeigen
docker compose logs -f paperless

# Logs anderer Services
docker compose logs -f database
docker compose logs -f redis
```

## Ressourcenlimits

| Service | CPU Limit | Memory Limit |
|---------|-----------|--------------|
| paperless | 2 | 2G |
| database | 1 | 512M |
| redis | 0.5 | 256M |
| gotenberg | 1 | 1G |
| tika | 2 | 2G |
