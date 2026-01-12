# Paperless-ngx Setup für Portainer + Nginx Proxy Manager

## 📁 Dateien in diesem Ordner

| Datei | Beschreibung |
|-------|--------------|
| `docker-compose.yml` | Hauptkonfiguration für einzelne Paperless-Instanz |
| `docker-compose.shared.yml` | Geteilte Services (Gotenberg, Tika) - einmalig deployen |
| `README.md` | Diese Datei - Hauptanleitung |
| `MULTI-INSTANZ.md` | Schnellanleitung für Multi-Instanz-Setup |
| `Update und Restore.md` | Backup und Wiederherstellung |

## Übersicht

Dieses Setup bietet eine vollständige Paperless-ngx Installation mit PostgreSQL-Datenbank, Redis und OCR-Services, optimiert für:
- **Portainer**: Deployment via Stacks
- **Nginx Proxy Manager**: Reverse Proxy mit SSL
- **Multi-Instanz-Support**: Mehrere Paperless-Instanzen können gemeinsame OCR-Services nutzen

## Architektur

Das Setup ist in zwei Teile aufgeteilt:

### 1. Geteilte Services (docker-compose.shared.yml)
- **Gotenberg**: PDF-Konvertierung
- **Tika**: OCR und Dokumentenanalyse
- Wird von ALLEN Paperless-Instanzen gemeinsam genutzt
- Muss nur EINMAL deployed werden

### 2. Instanz-spezifische Services (docker-compose.yml)
- **Paperless**: Hauptanwendung
- **PostgreSQL**: Datenbank (pro Instanz)
- **Redis**: Cache (pro Instanz)
- Kann beliebig oft deployed werden (privat, firma, etc.)

## Deployment in Portainer

### Schritt 1: Geteilte Services deployen (einmalig)

1. Gehe zu **Stacks** → **Add Stack**
2. Name: `paperless-shared`
3. Füge den Inhalt der `docker-compose.shared.yml` ein
4. Klicke auf **Deploy the stack**

⚠️ **Wichtig**: Dieser Stack muss zuerst deployed werden und nur EINMAL!

### Schritt 2: Erste Paperless-Instanz deployen

1. Gehe zu **Stacks** → **Add Stack**
2. Name: `paperless-main` (oder beliebig)
3. Füge den Inhalt der `docker-compose.yml` ein
4. Scrolle zu **Environment variables** und setze:

| Variable | Default | Beschreibung |
|----------|---------|-------------|
| `INSTANCE_NAME` | `main` | Eindeutiger Name für diese Instanz |
| `INSTANCE_PORT` | `61349` | Externer Port für diese Instanz |
| `PAPERLESS_ADMIN_USER` | `admin` | Admin-Benutzername |
| `PAPERLESS_ADMIN_PASSWORD` | `changeme` | Admin-Passwort ⚠️ **Ändern!** |
| `PAPERLESS_SECRET_KEY` | - | Django Secret Key ⚠️ **Pflichtfeld!** (Generieren!) |
| `DB_PASSWORD` | `changeme` | Datenbank-Passwort ⚠️ **Ändern!** |

5. Klicke auf **Deploy the stack**

### Schritt 3: Weitere Instanzen deployen (optional)

Für jede weitere Instanz (z.B. "privat", "firma"):

1. Gehe zu **Stacks** → **Add Stack**
2. Name: `paperless-privat` (oder beliebig)
3. Füge den Inhalt der `docker-compose.yml` ein
4. Setze **unterschiedliche** Environment Variables:

| Variable | Beispiel Instanz 2 | Beispiel Instanz 3 |
|----------|-------------------|-------------------|
| `INSTANCE_NAME` | `privat` | `firma` |
| `INSTANCE_PORT` | `61350` | `61351` |
| `PAPERLESS_ADMIN_USER` | `admin` | `admin` |
| `PAPERLESS_ADMIN_PASSWORD` | `anderes-passwort` | `noch-ein-passwort` |
| `PAPERLESS_SECRET_KEY` | `neuer-secret-key` | `weiterer-secret-key` |
| `DB_PASSWORD` | `anderes-db-passwort` | `noch-ein-db-passwort` |

5. Klicke auf **Deploy the stack**

⚠️ **Wichtig**: 
- Jede Instanz braucht einen **eindeutigen** `INSTANCE_NAME`
- Jede Instanz braucht einen **unterschiedlichen** `INSTANCE_PORT`
- Jede Instanz braucht einen **neuen** `PAPERLESS_SECRET_KEY`

## Dokumente hochladen

### Via Web-Interface

1. Klicke auf das **+** Symbol oben rechts
2. Wähle **Upload Document**
3. Ziehe Dateien per Drag & Drop oder wähle sie aus

### Via Consume-Ordner (automatischer Import)

1. Lege Dokumente in den `consume`-Ordner der jeweiligen Instanz:
   - Bei Verwendung von Docker Volumes: Zugriff über Docker
   - Bei lokalem Mount: Direkter Dateizugriff

2. Paperless überwacht diesen Ordner und importiert neue Dateien automatisch

**Zugriff auf Consume-Ordner:**
```powershell
# Für Instanz "main"
docker cp mein-dokument.pdf paperless_main:/usr/src/paperless/consume/

# Für Instanz "privat"
docker cp mein-dokument.pdf paperless_privat:/usr/src/paperless/consume/

# Für Instanz "firma"
docker cp mein-dokument.pdf paperless_firma:/usr/src/paperless/consume/

# Volume mounten (Windows)
docker run --rm -v paperless_consume_main:/consume -v ${PWD}:/backup alpine sh -c "cp /backup/*.pdf /consume/"
```

### Ordner als Tags

Wenn `PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS=true` gesetzt ist:
- Unterordner im consume-Verzeichnis werden automatisch als Tags verwendet
- Beispiel: `consume/Rechnungen/rechnung.pdf` → Tag "Rechnungen"

## Konfiguration

### OCR-Sprachen

Unterstützte Sprachen (durch `+` trennen):
- `deu` - Deutsch
- `eng` - Englisch
- `fra` - Französisch
- `spa` - Spanisch
- `ita` - Italienisch

Beispiel: `PAPERLESS_OCR_LANGUAGE=deu+eng+fra`

### Zusätzliche Einstellungen

Alle Einstellungen können in der `docker-compose.yml` unter den Environment-Variablen angepasst werden:

- `PAPERLESS_URL`: Externe URL für E-Mail-Links
- `PAPERLESS_CONSUMER_DELETE_DUPLICATES`: Duplikate automatisch löschen
- `PAPERLESS_CONSUMER_RECURSIVE`: Unterordner durchsuchen
- `PAPERLESS_CONSUMER_POLLING`: Intervall für Consume-Ordner (Sekunden)
