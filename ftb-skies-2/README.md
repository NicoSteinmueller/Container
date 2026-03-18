# FTB Skies 2 Minecraft Server

Docker-Container für FTB Skies 2 Modpack mit tzg/minecraft-server.

## Starten

```bash
docker-compose up -d
```

## Stoppen

```bash
docker-compose down
```

## Konfiguration

### Umgebungsvariablen
```
# Verzeichnisse
DATA_DIR=./data              # Server-Daten und Konfiguration
BACKUPS_DIR=./backups        # FTB-Backups (ftbbackups3)
WORLDS_DIR=./worlds          # Welt-Dateien

# Welt-Konfiguration
WORLD_NAME=/worlds/world.zip # Pfad zur Welt (ZIP oder Ordner)
FORCE_WORLD_COPY=false       # true = bei jedem Start neu kopieren
```

### Docker-Umgebungsvariablen

- **EULA**: Muss auf `TRUE` gesetzt werden, um die Minecraft EULA zu akzeptieren
- **TYPE**: `FTBA` für FTB App Modpacks
- **FTB_MODPACK_ID**: `129` für FTB Skies 2
- **FTB_MODPACK_VERSION_ID**: `100162` für eine spezifische Version
- **INIT_MEMORY**: `6G` - Initialer RAM
- **MAX_MEMORY**: `8G` - Maximaler RAM
- **TZ**: `Europe/Berlin` - Zeitzone
- **ONLINE_MODE**: `true` - Microsoft-Authentifizierung (korrekte UUIDs)

### Ports

- **25565**: Standard Minecraft Server Port

### Volumes

- `./data`: Laufende Server-Daten (Config, Mods, Player-Daten, aktive Welt)
- `./backups`: Ingame-Backups aus `ftbbackups3`
- `./worlds`: Import-Quelle für Welt-ZIP/Ordner (`WORLD_NAME`)

## Server-Einstellungen anpassen

Server-Eigenschaften können in `./data/server.properties` angepasst werden, nachdem der Server einmal gestartet wurde.

## Logs anzeigen

```bash
docker-compose logs -f
```

## Backup

Mindestens diese Pfade regelmäßig sichern:

- `./data/world`, `./data/server.properties`, `./data/config`, `./data/defaultconfigs`, `./data/mods`, `./data/kubejs`, `./data/local`, `./data/ftbteambases`
- `./data` Spielerdateien wie `ops.json`, `whitelist.json`, `banned-players.json`, `banned-ips.json`, `usercache.json`, `usernamecache.json`
- `./backups` (FTB Ingame-Backups)

Kann in Backups meist ausgeschlossen werden (rekonstruierbar oder nur Diagnose):

- `./data/logs`, `./data/crash-reports`, `./data/tmp`
- `./data/jre` (wird vom Installer erneut bereitgestellt)
- `./worlds` (nur nötig, wenn dort eigene Seed-ZIPs dauerhaft abgelegt werden)

## Hinweise

- Beim ersten Start lädt der Server das komplette Modpack herunter, dies kann einige Zeit dauern
- Mindestens 4GB RAM werden empfohlen, für optimale Performance 6-8GB
- Der Server benötigt beim ersten Start mehr Zeit zum Generieren der Welt

