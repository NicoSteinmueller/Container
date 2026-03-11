# 📁 Server-Ordnerstruktur – Entwurf

> **Ziel:** Klare Trennung von zu sichernden Daten, Konfigurationen, Logs, Caches und temporären
> Daten. Alle produktiven Nutzdaten liegen direkt unter `/srv/` in thematischen Hauptordnern und
> sind damit einfach mit Kopia zu sichern. IOPS-intensive Dienste liegen unter `/srv/db/` –
> dieser **eine** Ordner wird auf der SSD gemountet.

---

## 🗂️ Übersicht – Top-Level-Struktur

```
/srv/                          ← Wurzel (HDD/NAS) – Kopia sichert alles hier
│
├── config/                    ← App-Konfigurationen & kleine persistente Daten  ✅ SICHERN
├── media/                     ← Große Mediendaten (Fotos, Dokumente, Dateien)   ✅ SICHERN
├── db/                        ← Datenbanken & Caches  ⚡ → SSD-Mount-Point      ✅ SICHERN*
│
/var/log/containers/           ← Zentrale Container-Logs                         ❌ kein Backup
/tmp/containers/               ← Temporäre Daten                                 ❌ kein Backup
```

> ⚡ **SSD-Strategie:** Die SSD wird als **einziger Block-Device** unter `/srv/db/` eingehängt.
> Damit profitieren alle Datenbanken und Caches automatisch von der SSD-Geschwindigkeit.
> Da die SSD klein ist, liegen hier **ausschließlich** DB-Daten und kleine Caches –
> keine Medien oder Log-Dateien.
>
> \* Datenbanken müssen über `pg_dump` o. ä. konsistent gesichert werden (nicht im laufenden
> Betrieb per rsync/Kopia).

---

## 📂 Detaillierte Verzeichnisstruktur

### `/srv/config/` – App-Konfigurationen & persistente Daten (HDD)

```
/srv/config/
│
├── adguard/
│   ├── conf/                  ← DNS-Regeln, Filterlisten, DHCP-Konfig       ✅ SICHERN
│   └── work/                  ← Laufzeit-Daten (Statistiken)                ✅ SICHERN
│
├── ftb-skies-2/
│   ├── data/                  ← Server-Daten, Mods, Konfigurationen         ✅ SICHERN
│   └── worlds/                ← Welten-Backups (Import-Quelle)              ✅ SICHERN
│
├── immich/                    ← Immich-Konfigurationsdateien                 ✅ SICHERN
│
├── kopia/
│   └── config/                ← Repository-Verbindungsinfos                 ✅ SICHERN
│
├── monitoring/
│   └── grafana/               ← Dashboards, Benutzer, Einstellungen         ✅ SICHERN
│
├── nextcloud/
│   ├── apps/                  ← Installierte/modifizierte Apps              ✅ SICHERN
│   ├── config/                ← config.php & lokale Konfiguration           ✅ SICHERN
│   └── themes/                ← Themes/Branding                             ✅ SICHERN
│
├── octoprint/                 ← Profile, GCode-Dateien, Plugins             ✅ SICHERN
│
├── paperless/
│   └── main/
│       ├── consume/           ← Import-Eingangsordner (kurzlebig)           ➖ optional
│       └── export/            ← Exportierte Dokumente                       ✅ SICHERN
│
├── sftpgo/
│   ├── config/                ← SFTPGo-Konfiguration, Schlüssel             ✅ SICHERN
│   └── data/                  ← Benutzerdaten/Dateispeicher                 ✅ SICHERN
│
└── traefik/                   ← Routing-Regeln, CrowdSec-Daten, TLS-Zerts  ✅ SICHERN
```

### `/srv/media/` – Große Mediendaten (HDD)

```
/srv/media/
│
├── immich/                    ← Fotos & Videos (Upload-Verzeichnis)         ✅ SICHERN
│
├── nextcloud/                 ← Nextcloud-Benutzerdaten                     ✅ SICHERN
│
└── paperless/
    └── main/
        └── media/             ← Archivierte Dokumente & PDFs                ✅ SICHERN
```

### `/srv/db/` – Datenbanken & Caches (⚡ SSD-Mount-Point)

```
/srv/db/                       ← Dieser Ordner liegt komplett auf der SSD
│                                 (SSD eingehängt als /srv/db/)
│
├── keycloak-postgres/         ← PostgreSQL (Realms, User, Clients)         ✅ SICHERN*
├── nextcloud-postgres/        ← PostgreSQL (Datei-Metadaten, Shares)       ✅ SICHERN*
├── nextcloud-redis/           ← Redis/Valkey Session-Cache                  ❌ wegwerfbar
├── paperless-postgres/        ← PostgreSQL (Dokumentenindex, Volltextsuche)✅ SICHERN*
├── sftpgo-postgres/           ← PostgreSQL (Benutzer, Verbindungen)        ✅ SICHERN*
├── immich-postgres/           ← PostgreSQL (Foto-Metadaten, Alben)         ✅ SICHERN*
├── immich-redis/              ← Redis/Valkey (Job-Queue)                    ❌ wegwerfbar
└── kopia-cache/               ← Deduplizierungs-Lookup-Cache               ❌ wegwerfbar
```

> **Größenabschätzung SSD:** PostgreSQL-Datenbanken sind i. d. R. klein (< 5 GB pro Instanz).
> Redis-Daten sind minimal (< 100 MB). Der Kopia-Cache wächst mit dem Repository –
> ggf. per Kopia-Einstellung (`--cache-directory`, `--max-cache-size`) begrenzen.

### `/var/log/containers/` – Zentrale Log-Sammlung (HDD)

```
/var/log/containers/
│
├── traefik/                   ← Access- & Error-Logs (Promtail-Quelle)
└── ...                        ← Weitere Dienste nach Bedarf
```

> Logs sind über **Loki** zentral durchsuchbar → **kein Backup nötig**.
> Promtail-Konfiguration auf `/var/log/containers/traefik/` anpassen.

---

## ⚡ SSD-Strategie: Warum `/srv/db/` als einziger Mount-Point?

| Vorteil | Erklärung |
|---------|-----------|
| **Einfachheit** | Ein `mount`-Eintrag in `/etc/fstab`, keine Symlinks, kein Mapping |
| **Alle DBs profitieren** | Jeder neue Dienst mit DB legt seinen Ordner einfach unter `/srv/db/` an |
| **Backup-fähig** | `/srv/db/` liegt zwar auf SSD, gehört aber trotzdem zu `/srv/` → Kopia kann sichern |
| **Klar begrenzt** | Nur DB-Daten & kleine Caches → SSD wird nicht mit Medien vollgeschrieben |

**fstab-Eintrag (Beispiel):**
```
UUID=<ssd-uuid>   /srv/db   ext4   defaults,noatime   0 2
```

---

## 🔐 Backup-Klassifizierung

### ✅ Muss gesichert werden

| Pfad | Dienst | Inhalt |
|------|--------|--------|
| `/srv/media/immich/` | Immich | Fotos & Videos – **nicht reproduzierbar** |
| `/srv/media/nextcloud/` | Nextcloud | Benutzerdateien |
| `/srv/media/paperless/*/media/` | Paperless | Archivierte Dokumente |
| `/srv/db/*-postgres/` | Alle mit DB | Datenbanken (pg_dump empfohlen!) |
| `/srv/config/adguard/` | AdGuard | DNS-Regeln, Filter, DHCP |
| `/srv/config/traefik/` | Traefik | Routing-Regeln, TLS-Zertifikate, CrowdSec |
| `/srv/config/kopia/config/` | Kopia | Repository-Verbindungsinfos |
| `/srv/config/octoprint/` | OctoPrint | 3D-Drucker-Profile, GCode-Dateien |
| `/srv/config/sftpgo/` | SFTPGo | Benutzer-Konfiguration, Schlüssel |
| `/srv/config/monitoring/grafana/` | Grafana | Dashboards, Benutzer |
| `/srv/config/ftb-skies-2/` | Minecraft | Welt, Spielerfortschritt, Mods |

### ♻️ Wegwerfbar / kein Backup nötig

| Pfad | Dienst | Grund |
|------|--------|-------|
| `/srv/db/nextcloud-redis/` | Nextcloud | Session-Cache, nach Neustart neu aufgebaut |
| `/srv/db/immich-redis/` | Immich | Job-Queue, nach Neustart neu aufgebaut |
| `/srv/db/kopia-cache/` | Kopia | Deduplizierungs-Cache, wird neu aufgebaut |
| `/var/log/containers/` | Alle | Logs sind in Loki durchsuchbar |
| `/tmp/containers/` | Alle | Temporäre Daten |
| `/srv/config/paperless/*/consume/` | Paperless | Import-Eingang, nach Verarbeitung leer |

---

## 🔧 Umgebungsvariablen – Übersicht

| Dienst | Variable | Neuer Wert |
|--------|---------|------------|
| AdGuard | `ADGUARD_DATA` | `/srv/config/adguard` |
| FTB Skies 2 | `DATA_DIR` | `/srv/config/ftb-skies-2/data` |
| FTB Skies 2 | `WORLDS_DIR` | `/srv/config/ftb-skies-2/worlds` |
| Immich | `UPLOAD_LOCATION` | `/srv/media/immich` |
| Immich | postgres-Volume | `/srv/db/immich-postgres:/var/lib/postgresql` |
| Immich | model-cache-Volume | `/srv/db/immich-ml-cache:/cache` |
| Keycloak | postgres-Volume | `/srv/db/keycloak-postgres:/var/lib/postgresql` |
| Kopia | `KOPIA_DATA_DIR` | `/srv/config/kopia` |
| Kopia | `KOPIA_REPOSITORY_DIR` | _(externes Backup-Ziel – unverändert)_ |
| Monitoring | Grafana-Volume | `/srv/config/monitoring/grafana:/var/lib/grafana` |
| Monitoring | Prometheus-Volume | `/srv/config/monitoring/prometheus:/prometheus` _(auf HDD, wächst groß)_ |
| Nextcloud | `NEXTCLOUD_DATA` | `/srv/config/nextcloud` |
| Nextcloud | data-Unterordner | `/srv/media/nextcloud:/var/www/html/data` |
| Nextcloud | postgres-Volume | `/srv/db/nextcloud-postgres:/var/lib/postgresql` |
| Nextcloud | redis-Volume | `/srv/db/nextcloud-redis:/data` |
| OctoPrint | `OCTOPRINT_DATA` | `/srv/config/octoprint` |
| Paperless | `PAPERLESS_DATA_BASE_PATH` | `/srv/media/paperless` (media/export) + `/srv/config/paperless` (consume) |
| Paperless | postgres-Volume | `/srv/db/paperless-postgres:/var/lib/postgresql` |
| SFTPGo | `DATA_BASE_PATH` | `/srv/config/sftpgo` |
| Traefik | config-Volume | `/srv/config/traefik` |
| Traefik | logs-Volume | `/var/log/containers/traefik` |

> **Hinweis Prometheus:** Prometheus-Daten wachsen stetig (30-Tage-Retention) und können
> schnell mehrere GB erreichen → besser auf der HDD unter `/srv/config/monitoring/prometheus/`
> belassen, um die kleine SSD nicht zu füllen.

---

## 🛠️ Initialisierung – Setup-Befehle

```bash
# === SSD einbinden (vorher: UUID ermitteln mit 'blkid') ===
# /etc/fstab Eintrag:
# UUID=<ssd-uuid>  /srv/db  ext4  defaults,noatime  0 2
sudo mkdir -p /srv/db
sudo mount /srv/db   # oder: systemctl daemon-reload && mount -a

# === HDD / Haupt-Ordner ===
sudo mkdir -p /srv/config/{adguard/{conf,work},ftb-skies-2/{data,worlds},immich,kopia/config,monitoring/{grafana,prometheus},nextcloud/{apps,config,themes},octoprint,paperless/main/{consume,export},sftpgo/{config,data},traefik}
sudo mkdir -p /srv/media/{immich,nextcloud,paperless/main/media}

# === SSD – Datenbanken & Caches ===
sudo mkdir -p /srv/db/{keycloak-postgres,nextcloud-postgres,nextcloud-redis,paperless-postgres,sftpgo-postgres,immich-postgres,immich-redis,immich-ml-cache,kopia-cache}

# === Logs ===
sudo mkdir -p /var/log/containers/traefik

# === Berechtigungen (Postgres: UID 999, Grafana: UID 472, Standard: 1000) ===
sudo chown -R 1000:1000 /srv/config /srv/media
sudo chown -R 999:999   /srv/db/keycloak-postgres /srv/db/nextcloud-postgres /srv/db/paperless-postgres /srv/db/sftpgo-postgres /srv/db/immich-postgres
```

---

## 📐 Beispiel: docker-compose.yml Anpassung (Nextcloud)

```yaml
# Vorher:
volumes:
  - nextcloud:/var/www/html
  - ${NEXTCLOUD_DATA:-./data}/apps:/var/www/html/custom_apps
  - postgres:/var/lib/postgresql/data

# Nachher:
volumes:
  - nextcloud:/var/www/html                                        # Named Volume bleibt (Nextcloud-Updates)
  - /srv/config/nextcloud/apps:/var/www/html/custom_apps
  - /srv/config/nextcloud/config:/var/www/html/config
  - /srv/config/nextcloud/themes:/var/www/html/themes
  - /srv/media/nextcloud:/var/www/html/data                        # Große Nutzdaten → HDD
  - /srv/db/nextcloud-postgres:/var/lib/postgresql/data            # DB → SSD
  - /srv/db/nextcloud-redis:/data                                  # Redis → SSD
```

---

## ⚖️ Vor- und Nachteile dieser Struktur

### ✅ Vorteile

- **3 klare Hauptordner:** `config/` (klein, wichtig), `media/` (groß), `db/` (SSD)
- **SSD einfach:** Ein Mount-Point `/srv/db/` – alle DBs profitieren automatisch
- **Backup simpel:** `kopia snapshot /srv/` sichert alles – für DBs zusätzlich pg_dump empfohlen
- **Logs zentral:** Promtail sammelt mit einem Glob alle Container-Logs ein
- **Skalierbar:** Neuer Dienst → Ordner in `config/`, evtl. `db/`, fertig

### ⚠️ Nachteile / Hinweise

- **SSD-Größe beachten:** Kopia-Cache und Immich-ML-Cache können groß werden → per `--max-cache-size` bzw. Immich-Einstellung begrenzen
- **Migration nötig:** Bestehende Named Volumes müssen einmalig migriert werden (siehe unten)
- **DB-Backup:** Postgres-Daten nie per `rsync` im laufenden Betrieb sichern → `pg_dump` oder Kopia nach Container-Stop

---

## 🔄 Migrations-Hinweis (Named Volumes → Bind Mounts)

```bash
# Beispiel: Keycloak PostgreSQL-Volume → /srv/db/keycloak-postgres
docker run --rm \
  -v keycloak_postgres:/from \
  -v /srv/db/keycloak-postgres:/to \
  alpine sh -c "cp -av /from/. /to/"

# Danach in docker-compose.yml den Named Volume-Eintrag entfernen
# und durch Bind Mount ersetzen:
#   - /srv/db/keycloak-postgres:/var/lib/postgresql

# Stack neu starten:
docker compose down && docker compose up -d
```

---

*Stand: März 2026 · Struktur abgeleitet aus den vorhandenen docker-compose.yml-Dateien*
