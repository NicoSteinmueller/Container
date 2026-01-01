# Backrest - Restic Backup mit Web-UI

## Übersicht
Backrest ist eine moderne Web-UI für Restic Backup. Im Gegensatz zu Duplicati:
- **Keine anfällige lokale Datenbank** - Restic speichert alle Metadaten direkt im Repository
- **Schnelle Wiederherstellung** - kein Datenbank-Rebuild nötig
- **Effiziente Deduplizierung** - spart Speicherplatz
- **Verschlüsselung** - alle Backups sind standardmäßig verschlüsselt

## Installation

### 1. Pfade anpassen
Bearbeiten Sie die `docker-compose.yml` und passen Sie die Pfade an:

```yaml
# Quellordner (Ihre Daten)
- /pfad/zu/ihren/daten:/source:ro

# Backup-Zielordner  
- /pfad/zum/backup:/backup
```

**Beispiel:**
```yaml
- /home/nico/Dokumente:/source:ro
- /mnt/backup-disk:/backup
```

### 2. Container starten
```bash
docker compose up -d
```

### 3. Web-UI öffnen
Öffnen Sie im Browser: **http://localhost:9898**

## Erstkonfiguration in der Web-UI

1. **Repository erstellen:**
   - Klicken Sie auf "Add Repo"
   - Wählen Sie "Local" als Typ
   - Pfad: `/backup/mein-backup`
   - Vergeben Sie ein sicheres Passwort (WICHTIG: Gut aufbewahren!)

2. **Backup-Plan erstellen:**
   - Klicken Sie auf "Add Plan"
   - Wählen Sie Ihr Repository
   - Pfad zum Sichern: `/source`
   - Zeitplan festlegen (z.B. täglich um 02:00)

3. **Retention Policy:**
   - Behalten Sie z.B. die letzten 7 täglichen, 4 wöchentlichen, 12 monatlichen Backups

## Backup-Typen

| Typ | Beschreibung |
|-----|--------------|
| **Inkrementell** | Standard - nur Änderungen werden gesichert (schnell & platzsparend) |
| **Vollständig** | Restic macht immer "Full-like" Backups durch Deduplizierung |

> **Hinweis:** Restic verwendet Content-Addressable Storage. Jedes Backup ist technisch ein Vollbackup, aber durch Deduplizierung werden nur neue/geänderte Daten gespeichert.

## Vorteile gegenüber Duplicati

| Feature | Duplicati | Backrest/Restic |
|---------|-----------|-----------------|
| Datenbank-Korruption | Häufiges Problem | Kein Problem |
| Recovery ohne DB | Unmöglich | Jederzeit möglich |
| Geschwindigkeit | Langsam | Sehr schnell |
| Deduplizierung | Ja | Ja (effizienter) |
| Web-UI | Ja | Ja |

## Nützliche Befehle

```bash
# Container Logs anzeigen
docker logs backrest

# Container neustarten
docker compose restart

# Container stoppen
docker compose down
```

## Backup manuell überprüfen

In der Web-UI können Sie:
- Backup-Integrität prüfen
- Snapshots durchsuchen
- Einzelne Dateien wiederherstellen
- Statistiken einsehen

## Links
- [Backrest GitHub](https://github.com/garethgeorge/backrest)
- [Restic Dokumentation](https://restic.readthedocs.io/)

