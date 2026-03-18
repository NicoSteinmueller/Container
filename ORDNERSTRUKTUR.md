# Unraid Ordnerstruktur für Docker-Container

## Grundprinzip

| Pfad | Speicher | Zweck |
|---|---|---|
| `/mnt/cache/appdata/` | SSD-Cache ⚡ | Configs, DBs, App-Daten → **wird gesichert** |
| `/mnt/user/data/` | HDD-Array 🗄️ | Nutzerdaten & Medien → **wird gesichert** |
| `/mnt/user/logs/` | HDD-Array 🗄️ | Alle Logs → **kein Backup nötig** |
| `/mnt/user/backups/` | HDD-Array 🗄️ | Kopia-Repository (ist selbst das Backup) |

### Unraid Share-Einstellungen

| Share | Use Cache | Begründung |
|---|---|---|
| `appdata` | **Only** | Bleibt immer auf SSD, wird nie aufs Array verschoben |
| `data` | **No** | Direkt auf Array, kein SSD-Staging nötig |
| `logs` | **No** | Direkt auf Array, kein SSD-Staging nötig |
| `backups` | **No** | Repository direkt auf Array |

---

## Ordnerstruktur

```
/mnt/cache/appdata/                         ← SSD (schnell, Backup via Kopia)
├── adguard/
│   └── conf/                               ✅ Backup (DNS-Config, Filterlisten)
├── ftb-skies-2/
│   └── data/                               ✅ Backup (Server-Config, Mods, Player-Daten, aktive Welt)
├── immich/
│   └── db/                                 ✅ Backup (Postgres-Datenbank)
├── keycloak/
│   └── db/                                 ✅ Backup (Auth-Datenbank – kritisch!)
├── kopia/
│   └── config/                             ✅ Backup (Kopia-Konfiguration & Cache)
├── monitoring/
│   ├── grafana/                            ✅ Backup (Dashboards, Alerting-Config)
│   ├── prometheus/                         ✅ Backup (optional – Metriken-History)
│   └── loki/                               ✅ Backup (optional – Log-History)
├── nextcloud/
│   ├── app/                                ✅ Backup (Apps, Themes, Config)
│   ├── html/                               ✅ Backup (Nextcloud-Core / named volume)
│   └── db/                                 ✅ Backup (Postgres-Datenbank)
├── octoprint/                              ✅ Backup (Configs, GCode-Profile)
├── paperless/
│   ├── app-data/                           ✅ Backup (Search-Index, KI-Classifier)
│   └── db/                                 ✅ Backup (Postgres-Datenbank)
├── sftpgo/
│   ├── config/                             ✅ Backup (SFTPGo-Konfiguration)
│   └── db/                                 ✅ Backup (User-Datenbank)
└── traefik/
    ├── config/                             ✅ Backup (traefik.yml, dynamic configs)
    ├── letsencrypt/                        ✅ Backup (TLS-Zertifikate!)
    ├── crowdsec-config/                    ✅ Backup (CrowdSec-Konfiguration)
    └── crowdsec-data/                      ✅ Backup (CrowdSec-Datenbank)

/mnt/user/data/                             ← HDD-Array (Nutzerdaten, wird gesichert)
├── ftb-skies-2/
│   ├── worlds/                             ✅ Backup (Welt-Importe / Seed-ZIPs)
│   └── backups/                            ✅ Backup (FTB Ingame-Backups / Snapshots)
├── immich/
│   ├── media/                              ✅ Backup (Originalfotos/-videos)
│   └── model-cache/                        ❌ Kein Backup (ML-Modelle – auto-download)
├── nextcloud/
│   └── data/                               ✅ Backup (Benutzerdateien)
├── paperless/
│   ├── media/                              ✅ Backup (verarbeitete Dokumente)
│   ├── export/                             ✅ Backup (Paperless-Exporte)
│   └── consume/                            ❌ Kein Backup (Eingangsordner – temporär)
└── sftpgo/
    └── data/                               ✅ Backup (SFTP-Nutzerdaten)

/mnt/user/logs/                             ← HDD-Array (Logs, kein Backup)
├── adguard/                                ❌ Kein Backup (Query-Logs, Stats – regenerierbar)
├── kopia/                                  ❌ Kein Backup
├── traefik/                                ❌ Kein Backup (Promtail-Quelle)
└── immich/                                 ❌ Kein Backup (ML model-cache-Logs)

/mnt/user/backups/                          ← HDD-Array
└── kopia-repos/                            Kopia-Repository
```

---

## Kopia-Backup-Quellen

```
# Configs, DBs, App-Daten (SSD):
/mnt/cache/appdata/

# Nutzerdaten & Medien (Array):
/mnt/user/data/paperless/media/
/mnt/user/data/paperless/export/
/mnt/user/data/nextcloud/data/
/mnt/user/data/sftpgo/data/
/mnt/user/data/ftb-skies-2/worlds/
/mnt/user/data/ftb-skies-2/backups/
/mnt/user/data/immich/media/        # nur wenn Immich die einzige Kopie ist
```

---

## Umgebungsvariablen pro Container

### AdGuard

```env
ADGUARD_DATA=/mnt/cache/appdata/adguard
```

> Die `conf/` und `work/` Unterordner werden automatisch erstellt. `work/` enthält
> Query-Logs und Statistiken – diese gehören in den Logs-Share:
> - `${ADGUARD_DATA}/work` → direkt im Compose auf `/mnt/user/logs/adguard` umbiegen

---

### FTB Skies 2

```env
DATA_DIR=/mnt/cache/appdata/ftb-skies-2/data
BACKUPS_DIR=/mnt/user/data/ftb-skies-2/backups
WORLDS_DIR=/mnt/user/data/ftb-skies-2/worlds
```

---

### Immich

```env
UPLOAD_LOCATION=/mnt/user/data/immich/media
DB_PASSWORD=<sicheres_passwort>
```

> **Named Volumes → Bind Mounts umstellen:**
> - `postgres` → `/mnt/cache/appdata/immich/db:/var/lib/postgresql`
> - `model-cache` → `/mnt/user/data/immich/model-cache:/cache`

---

### Keycloak

```env
DB_PASSWORD=<sicheres_passwort>
KEYCLOAK_ADMIN_USER=admin
KEYCLOAK_ADMIN_PASSWORD=<sicheres_passwort>
```

> **Named Volume → Bind Mount umstellen:**
> - `postgres` → `/mnt/cache/appdata/keycloak/db:/var/lib/postgresql`

---

### Kopia

```env
KOPIA_DATA_DIR=/mnt/cache/appdata/kopia
KOPIA_REPOSITORY_DIR=/mnt/user/backups/kopia-repos
KOPIA_REPOSITORY_PASSWORD=<sicheres_passwort>
KOPIA_SERVER_USERNAME=admin
KOPIA_SERVER_PASSWORD=<sicheres_passwort>

# Quellpfade:
KOPIA_SOURCE_1=/mnt/cache/appdata
KOPIA_SOURCE_1_NAME=appdata
KOPIA_SOURCE_2=/mnt/user/data/paperless/media
KOPIA_SOURCE_2_NAME=paperless-media
KOPIA_SOURCE_3=/mnt/user/data/paperless/export
KOPIA_SOURCE_3_NAME=paperless-export
KOPIA_SOURCE_4=/mnt/user/data/nextcloud/data
KOPIA_SOURCE_4_NAME=nextcloud-data
KOPIA_SOURCE_5=/mnt/user/data/sftpgo/data
KOPIA_SOURCE_5_NAME=sftpgo-data
KOPIA_SOURCE_6=/mnt/user/data/ftb-skies-2/worlds
KOPIA_SOURCE_6_NAME=ftb-worlds
KOPIA_SOURCE_7=/mnt/user/data/ftb-skies-2/backups
KOPIA_SOURCE_7_NAME=ftb-backups
# Nur wenn Immich die einzige Kopie der Fotos ist:
# KOPIA_SOURCE_8=/mnt/user/data/immich/media
# KOPIA_SOURCE_8_NAME=immich-media
```

---

### Monitoring (Prometheus / Grafana / Loki / Promtail)

```env
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=<sicheres_passwort>
```

> **Named Volumes → Bind Mounts umstellen:**
> - `prometheus-data` → `/mnt/cache/appdata/monitoring/prometheus:/prometheus`
> - `loki-data` → `/mnt/cache/appdata/monitoring/loki:/loki`
> - `grafana-data` → `/mnt/cache/appdata/monitoring/grafana:/var/lib/grafana`
>
> **Traefik-Logs Pfad anpassen** (Promtail-Volume):
> - `../traefik/logs` → `/mnt/user/logs/traefik`

---

### Nextcloud

```env
POSTGRES_PASSWORD=<sicheres_passwort>
NEXTCLOUD_DATA=/mnt/cache/appdata/nextcloud/app
PAPERLESS_DATA=/mnt/user/data/paperless/consume
```

> **Named Volumes → Bind Mounts umstellen:**
> - `nextcloud` → `/mnt/cache/appdata/nextcloud/html:/var/www/html`
> - `postgres` → `/mnt/cache/appdata/nextcloud/db:/var/lib/postgresql/data`
>
> **Benutzerdaten-Pfad** (in `NEXTCLOUD_DATA`-Struktur):
> Das Volume `${NEXTCLOUD_DATA}/data` zeigt auf `/var/www/html/data` – dieser Pfad
> enthält die eigentlichen Benutzerdateien. Für große Datenmengen empfiehlt sich:
> - `${NEXTCLOUD_DATA}/data` → stattdessen `/mnt/user/data/nextcloud/data`
> (erfordert direktes Anpassen im Compose)

---

### Octoprint

```env
OCTOPRINT_DATA=/mnt/cache/appdata/octoprint
```

---

### Paperless-ngx

```env
INSTANCE_NAME=main
DB_PASSWORD=<sicheres_passwort>
PAPERLESS_SECRET_KEY=<mindestens_50_zeichen>
PAPERLESS_DATA_BASE_PATH=/mnt/user/data/paperless
PAPERLESS_URL=https://paperless-main.nico-steinmueller.de
```

> **Named Volumes → Bind Mounts umstellen:**
> - `postgres` → `/mnt/cache/appdata/paperless/db:/var/lib/postgresql`
> - `data` (app-data / Search-Index) → `/mnt/cache/appdata/paperless/app-data:/usr/src/paperless/data`

---

### SFTPGo

```env
DB_PASSWORD=<sicheres_passwort>
DATA_BASE_PATH=/mnt/cache/appdata/sftpgo
```

> `DATA_BASE_PATH` steuert `config/`, `backups/` auf dem SSD-Cache.
> Upload-Daten der SFTP-Nutzer liegen separat auf dem Array:
> - Entsprechendes Volume im Compose direkt auf `/mnt/user/data/sftpgo/data` setzen.
>
> **Named Volume → Bind Mount umstellen:**
> - `postgres` → `/mnt/cache/appdata/sftpgo/db:/var/lib/postgresql`

---

### Traefik

```env
IONOS_API_KEY=<api_key>
CROWDSEC_ENROLL_KEY=<enroll_key>
TRAEFIK_LOCATION=/mnt/cache/appdata/traefik
```

> **Named Volumes → Bind Mounts umstellen:**
> - `letsencrypt` → `/mnt/cache/appdata/traefik/letsencrypt:/letsencrypt`
> - `crowdsec-data` → `/mnt/cache/appdata/traefik/crowdsec-data:/var/lib/crowdsec/data`
> - `crowdsec-config` → `/mnt/cache/appdata/traefik/crowdsec-config:/etc/crowdsec`
> - `geoblock` → `/mnt/cache/appdata/traefik/geoblock:/data/geoblock` ❌ kein Backup (auto-download)
>
> **Logs-Pfad** – Traefik und CrowdSec schreiben Logs in den Logs-Share:
> - `${TRAEFIK_LOCATION:-.}/logs` → `/mnt/user/logs/traefik`

---

## Hinweise

### Named Volumes → Bind Mounts

Folgende Container nutzen aktuell **Named Volumes** für Postgres-Datenbanken. Diese müssen
auf **Bind Mounts** umgestellt werden, damit Kopia direkt sichern kann:

| Container | Named Volume | Bind Mount (Ziel) |
|---|---|---|
| Immich | `postgres` | `/mnt/cache/appdata/immich/db` |
| Keycloak | `postgres` | `/mnt/cache/appdata/keycloak/db` |
| Nextcloud | `postgres` | `/mnt/cache/appdata/nextcloud/db` |
| Paperless | `postgres` | `/mnt/cache/appdata/paperless/db` |
| SFTPGo | `postgres` | `/mnt/cache/appdata/sftpgo/db` |
| Monitoring | `prometheus-data`, `loki-data`, `grafana-data` | Siehe oben |
| Traefik | `letsencrypt`, `crowdsec-data`, `crowdsec-config` | Siehe oben |

**Alternative:** Pre-Backup-Script mit `docker exec ... pg_dump` ausführen, dann
können Named Volumes bestehen bleiben.

### Immich `media/` – Backup-Entscheidung

- Immich ist die **einzige Kopie** der Fotos → `media/` ebenfalls sichern (Variable in Kopia ergänzen)
- Originale noch auf Handy/Cloud vorhanden → kein separates Backup nötig

### 200 GB SSD reicht aus

Alle `appdata`-Pfade zusammen umfassen typischerweise nur wenige GB
(Datenbanken + Configs). Die großen Daten (Medien, Logs) liegen auf dem Array.








