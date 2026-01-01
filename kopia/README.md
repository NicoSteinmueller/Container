# Kopia Backup

## Übersicht
Kopia ist ein schnelles und sicheres Open-Source-Backup-Tool mit eingebauter Web-UI.

## Installation

### 1. Pfade anpassen
Bearbeiten Sie die `docker-compose.yml` und passen Sie die Pfade an:

```yaml
# Quellordner (Ihre Daten)
- /pfad/zu/ihren/daten:/source:ro

# Backup-Zielordner  
- /pfad/zum/backup:/backup
```

### 2. (Optional) Zugangsdaten ändern
Standardmäßig:
- **Benutzer:** `admin`
- **Passwort:** `kopia123`

Ändern Sie diese in der `docker-compose.yml`:
```yaml
- --server-username=IhrBenutzer
- --server-password=IhrSicheresPasswort
```

### 3. Container starten
```bash
docker compose up -d
```

### 4. Web-UI öffnen
Öffnen Sie im Browser: **http://localhost:51515**

Login mit den konfigurierten Zugangsdaten.

## Erstkonfiguration in der Web-UI

### 1. Repository erstellen
Beim ersten Start müssen Sie ein Repository erstellen:

1. Wählen Sie "Create New Repository"
2. Typ: **Local Directory** oder **Filesystem**
3. Pfad: `/backup`
4. Vergeben Sie ein Repository-Passwort (WICHTIG: Gut aufbewahren!)

### 2. Snapshot-Policy erstellen
1. Gehen Sie zu "Policies"
2. Erstellen Sie eine Policy für `/source`
3. Konfigurieren Sie:
   - Snapshot-Intervall (z.B. alle 6 Stunden)
   - Retention (z.B. 7 täglich, 4 wöchentlich, 12 monatlich)

### 3. Erstes Backup erstellen
1. Gehen Sie zu "Snapshots"
2. Klicken Sie auf "New Snapshot"
3. Wählen Sie `/source` als Pfad
4. Starten Sie das Backup

## Features

| Feature | Beschreibung |
|---------|--------------|
| **Deduplizierung** | Speichert nur einzigartige Daten-Blöcke |
| **Verschlüsselung** | AES-256-GCM Verschlüsselung |
| **Kompression** | Unterstützt zstd, gzip, etc. |
| **Snapshots** | Jedes Backup ist ein vollständiger Snapshot |
| **Policies** | Automatische Zeitpläne und Retention |

## Nützliche Befehle

```bash
# Container Logs anzeigen
docker logs kopia

# Container neustarten
docker compose restart

# Container stoppen
docker compose down

# In Container CLI einloggen
docker exec -it kopia /bin/sh
```

## CLI-Befehle (im Container)

```bash
# Repository-Status anzeigen
kopia repository status

# Snapshots auflisten
kopia snapshot list

# Manuelles Backup
kopia snapshot create /source

# Snapshot wiederherstellen
kopia restore <snapshot-id> /restore-ziel
```

## Links
- [Kopia Website](https://kopia.io/)
- [Kopia Dokumentation](https://kopia.io/docs/)
- [Kopia GitHub](https://github.com/kopia/kopia)

