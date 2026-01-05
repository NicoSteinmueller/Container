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

- `./data`: Speichert alle Server-Daten (Welten, Konfigurationen, Logs)

## Server-Einstellungen anpassen

Server-Eigenschaften können in `./data/server.properties` angepasst werden, nachdem der Server einmal gestartet wurde.

## Logs anzeigen

```bash
docker-compose logs -f
```

## Backup

Die Server-Daten befinden sich im `./data` Verzeichnis und sollten regelmäßig gesichert werden.

## Hinweise

- Beim ersten Start lädt der Server das komplette Modpack herunter, dies kann einige Zeit dauern
- Mindestens 4GB RAM werden empfohlen, für optimale Performance 6-8GB
- Der Server benötigt beim ersten Start mehr Zeit zum Generieren der Welt

