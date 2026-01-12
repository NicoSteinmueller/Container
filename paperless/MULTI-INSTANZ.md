# Multi-Instanz Setup - Schnellanleitung

Diese Anleitung zeigt, wie mehrere Paperless-Instanzen mit geteilten OCR-Services eingerichtet werden.

## Architektur-Übersicht

```
┌─────────────────────────────────────────────────────────────┐
│                    Geteilte Services                        │
│  ┌──────────────┐              ┌──────────────┐            │
│  │  Gotenberg   │              │     Tika     │            │
│  │ (PDF-Konv.)  │              │    (OCR)     │            │
│  └──────────────┘              └──────────────┘            │
│           paperless_shared Network                          │
└─────────────────────────────────────────────────────────────┘
                           ▲
                           │ (verwendet von allen Instanzen)
                           │
        ┌──────────────────┴──────────────────┐
        │                                     │
┌───────▼────────┐                  ┌────────▼────────┐
│  Instanz: main │                  │ Instanz: privat │
│                │                  │                 │
│  Paperless     │                  │  Paperless      │
│  PostgreSQL    │                  │  PostgreSQL     │
│  Redis         │                  │  Redis          │
│                │                  │                 │
│  Port: 61349   │                  │  Port: 61350    │
└────────────────┘                  └─────────────────┘
```

## Deployment-Reihenfolge

### 1️⃣ Geteilte Services deployen (EINMALIG)

**Stack-Name:** `paperless-shared`  
**Datei:** `docker-compose.shared.yml`

```yaml
# Keine Environment Variables nötig
# Einfach deployen!
```

### 2️⃣ Erste Instanz deployen

**Stack-Name:** `paperless-main`  
**Datei:** `docker-compose.yml`

**Environment Variables:**
```env
INSTANCE_NAME=main
INSTANCE_PORT=61349
PAPERLESS_ADMIN_USER=admin
PAPERLESS_ADMIN_PASSWORD=<SICHERES_PASSWORT>
PAPERLESS_SECRET_KEY=<GENERIERTER_SECRET_KEY>
DB_PASSWORD=<SICHERES_DB_PASSWORT>
```

### 3️⃣ Weitere Instanzen deployen (OPTIONAL)

**Stack-Name:** `paperless-privat`  
**Datei:** `docker-compose.yml` (gleiche Datei!)

**Environment Variables:**
```env
INSTANCE_NAME=privat
INSTANCE_PORT=61350
PAPERLESS_ADMIN_USER=admin
PAPERLESS_ADMIN_PASSWORD=<ANDERES_PASSWORT>
PAPERLESS_SECRET_KEY=<NEUER_SECRET_KEY>
DB_PASSWORD=<ANDERES_DB_PASSWORT>
```

## Secret Key generieren

**PowerShell:**
```powershell
-join ((48..57) + (65..90) + (97..122) | Get-Random -Count 50 | ForEach-Object {[char]$_})
```

**Linux/Mac:**
```bash
openssl rand -base64 32
```

## Wichtige Hinweise

✅ **Was wird geteilt:**
- Gotenberg (PDF-Konvertierung)
- Tika (OCR und Dokumentenanalyse)

❌ **Was wird NICHT geteilt:**
- PostgreSQL-Datenbank (jede Instanz hat ihre eigene)
- Redis-Cache (jede Instanz hat ihren eigenen)
- Dokumente und Medien (jede Instanz hat ihre eigenen Volumes)
- Benutzer und Einstellungen (komplett getrennt)

## Vorteile dieser Architektur

✨ **Ressourcen-Effizienz:**
- OCR-Services werden nur 1x benötigt (nicht 3x bei 3 Instanzen)
- Spart RAM und CPU

🔒 **Datentrennung:**
- Jede Instanz hat ihre eigene Datenbank
- Dokumente sind strikt getrennt
- Verschiedene Benutzer pro Instanz möglich

📈 **Skalierbarkeit:**
- Beliebig viele Instanzen können hinzugefügt werden
- Nur Port und Name müssen geändert werden
- Keine Konfigurationsänderungen an bestehenden Instanzen

## Ports

| Instanz | Empfohlener Port | Container-Name |
|---------|-----------------|----------------|
| main    | 61349          | paperless_main |
| privat  | 61350          | paperless_privat |
| firma   | 61351          | paperless_firma |
| kunde1  | 61352          | paperless_kunde1 |
| ...     | ...            | ... |

## Verwendungszwecke

### Beispiel 1: Privat & Geschäftlich
- **main** (61349): Persönliche Dokumente
- **firma** (61350): Geschäftsdokumente

### Beispiel 2: Mehrere Unternehmen/Mandate
- **kunde-a** (61349): Dokumente für Kunde A
- **kunde-b** (61350): Dokumente für Kunde B
- **kunde-c** (61351): Dokumente für Kunde C

### Beispiel 3: Familienmitglieder
- **papa** (61349): Dokumente von Papa
- **mama** (61350): Dokumente von Mama
- **kinder** (61351): Dokumente der Kinder

## Zugriff über Nginx Proxy Manager

Jede Instanz kann eine eigene Domain bekommen:

```
https://paperless.domain.de      → paperless_main:61349
https://paperless-privat.domain.de → paperless_privat:61350
https://paperless-firma.domain.de  → paperless_firma:61351
```

Oder über Subpaths (komplexer):
```
https://paperless.domain.de/main   → paperless_main:61349
https://paperless.domain.de/privat → paperless_privat:61350
```

## Wartung

### Alle Instanzen anzeigen
```powershell
docker ps | Select-String "paperless_"
```

### Bestimmte Instanz neustarten
```powershell
docker restart paperless_main
docker restart paperless_postgres_main
docker restart paperless_redis_main
```

### Geteilte Services neustarten
```powershell
docker restart paperless_shared_gotenberg
docker restart paperless_shared_tika
```

### Logs einer Instanz
```powershell
docker logs -f paperless_main
```

## Fehlerbehebung

### ❌ "Cannot connect to gotenberg/tika"

**Problem:** Das gemeinsame Netzwerk existiert nicht  
**Lösung:** Stelle sicher, dass `paperless-shared` Stack deployed ist

```powershell
docker network ls | Select-String "paperless_shared"
```

Falls nicht vorhanden, deploye zuerst `docker-compose.shared.yml`

### ❌ "Port already in use"

**Problem:** Der Port ist bereits belegt  
**Lösung:** Ändere `INSTANCE_PORT` in den Environment Variables

### ❌ "Container name already exists"

**Problem:** `INSTANCE_NAME` ist nicht eindeutig  
**Lösung:** Ändere `INSTANCE_NAME` in den Environment Variables

## Vollständiges Beispiel

### Schritt-für-Schritt: 3 Instanzen einrichten

1. **Shared Services deployen:**
   - Stack: `paperless-shared`
   - Datei: `docker-compose.shared.yml`
   - Keine Env-Vars

2. **Instanz "main" deployen:**
   - Stack: `paperless-main`
   - Datei: `docker-compose.yml`
   - Env: `INSTANCE_NAME=main`, `INSTANCE_PORT=61349`, etc.

3. **Instanz "privat" deployen:**
   - Stack: `paperless-privat`
   - Datei: `docker-compose.yml`
   - Env: `INSTANCE_NAME=privat`, `INSTANCE_PORT=61350`, etc.

4. **Instanz "firma" deployen:**
   - Stack: `paperless-firma`
   - Datei: `docker-compose.yml`
   - Env: `INSTANCE_NAME=firma`, `INSTANCE_PORT=61351`, etc.

**Fertig!** 🎉

Alle 3 Instanzen nutzen die gleichen Gotenberg/Tika Services, haben aber separate Datenbanken und Dokumente.

