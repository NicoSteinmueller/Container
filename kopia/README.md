# Kopia Backup

## Übersicht
Kopia ist ein schnelles und sicheres Open-Source-Backup-Tool mit eingebauter Web-UI.

## Installation

### 1. Umgebungsvariablen konfigurieren
Erstellen Sie eine `.env`-Datei im gleichen Verzeichnis wie die `docker-compose.yml`:

```bash
# Repository-Verschlüsselungspasswort (WICHTIG: Gut aufbewahren!)
KOPIA_REPOSITORY_PASSWORD=IhrSicheresPasswort123#

# Web-UI Zugangsdaten
KOPIA_SERVER_USERNAME=admin
KOPIA_SERVER_PASSWORD=kopia123

# Kopia Datenverzeichnis (optional)
KOPIA_DATA_DIR=./kopia-data

# Backup-Repository Speicherort (optional)
KOPIA_REPOSITORY_DIR=./backup

# Quellordner - Daten die gesichert werden sollen
KOPIA_SOURCE_1=./daten
KOPIA_SOURCE_1_NAME=daten

# Weitere Quellordner (optional)
KOPIA_SOURCE_2=/pfad/zu/ordner2
KOPIA_SOURCE_2_NAME=ordner2

KOPIA_SOURCE_3=/pfad/zu/ordner3
KOPIA_SOURCE_3_NAME=ordner3

# ... bis zu KOPIA_SOURCE_20 möglich
```

**Wichtige Hinweise:**
- `KOPIA_SOURCE_X`: Absoluter Pfad zum Quellordner auf dem Host
- `KOPIA_SOURCE_X_NAME`: Name unter dem der Ordner in `/data/` im Container erscheint
- Nicht konfigurierte Quellen produzieren Fehler - kommentieren Sie ungenutzte Zeilen in der `docker-compose.yml` aus

### 2. Container starten
```bash
docker compose up -d
```

### 3. Web-UI öffnen
Öffnen Sie im Browser: **http://localhost:51515**

Login mit den konfigurierten Zugangsdaten (Standard: admin / kopia123).

## Erstkonfiguration in der Web-UI

### 1. Repository erstellen
Beim ersten Start müssen Sie ein Repository erstellen:

1. Wählen Sie "Create New Repository"
2. Typ: **Local Directory** oder **Filesystem**
3. Pfad: `/repository`
4. Geben Sie das Repository-Passwort ein (aus KOPIA_PASSWORD)

**Wichtig:** Das Repository-Passwort muss mit der Umgebungsvariable `KOPIA_PASSWORD` übereinstimmen!

### 2. Snapshot-Policy erstellen
1. Gehen Sie zu "Policies"
2. Erstellen Sie Policies für Ihre Quellordner, z.B.:
   - `/data/daten`
   - `/data/ordner2`
   - `/data/ordner3`
3. Konfigurieren Sie für jede Policy:
   - Snapshot-Intervall (z.B. alle 6 Stunden)
   - Retention (z.B. 7 täglich, 4 wöchentlich, 12 monatlich)
   - Kompression (z.B. zstd)

### 3. Erstes Backup erstellen
1. Gehen Sie zu "Snapshots"
2. Klicken Sie auf "New Snapshot"
3. Wählen Sie einen Pfad aus `/data/` (z.B. `/data/daten`)
4. Starten Sie das Backup

## Features

| Feature | Beschreibung |
|---------|--------------|
| **Deduplizierung** | Speichert nur einzigartige Daten-Blöcke |
| **Verschlüsselung** | AES-256-GCM Verschlüsselung |
| **Kompression** | Unterstützt zstd, gzip, etc. |
| **Snapshots** | Jedes Backup ist ein vollständiger Snapshot |
| **Policies** | Automatische Zeitpläne und Retention |

## Umgebungsvariablen-Referenz

| Variable | Beschreibung | Standard |
|----------|--------------|----------|
| `KOPIA_PASSWORD` | Repository-Verschlüsselungspasswort | `kopia1#` |
| `KOPIA_SERVER_USERNAME` | Web-UI Benutzername | `admin` |
| `KOPIA_SERVER_PASSWORD` | Web-UI Passwort | `kopia123` |
| `KOPIA_PORT` | Web-UI Port | `51515` |
| `KOPIA_DATA_DIR` | Hauptverzeichnis für Kopia-Daten | `./kopia-data` |
| `KOPIA_REPOSITORY_DIR` | Backup-Repository Speicherort | `./backup` |
| `KOPIA_SOURCE_1..20` | Quellordner Pfad (absolut) | `./daten` (nur SOURCE_1) |
| `KOPIA_SOURCE_1..20_NAME` | Quellordner Name in /data | `daten` (nur SOURCE_1) |

**Hinweis:** Nicht konfigurierte SOURCE-Variablen (2-20) müssen in der `docker-compose.yml` auskommentiert werden!

## Links
- [Kopia Website](https://kopia.io/)
- [Kopia Dokumentation](https://kopia.io/docs/)
- [Kopia GitHub](https://github.com/kopia/kopia)

