# 📊 Monitoring Stack - Übersicht

## 🎯 Was wurde implementiert?

Ein **produktionsreifes Monitoring-System** basierend auf Prometheus + Grafana + Loki für Traefik.

### Stack-Komponenten

| Service | Version | Port | Funktion |
|---------|---------|------|----------|
| **Prometheus** | v3.2.0 | 9090 | Metriken-Sammlung & -Speicherung |
| **Grafana** | 11.5.1 | 3000 | Visualisierung & Dashboards |
| **Loki** | 3.3.2 | 3100 | Log-Aggregation & -Speicherung |
| **Promtail** | 3.3.2 | - | Log-Shipper (liest Traefik-Logs) |

## 📁 Dateien-Übersicht

```
monitoring/
├── 🚀 QUICKSTART.md          # 3-Minuten Setup (START HIER!)
├── 📚 README.md              # Vollständige Dokumentation
├── ✅ CHECKLIST.md           # Setup-Checkliste
├── 🔧 COMMANDS.md            # Alle wichtigen Befehle
├── 📊 QUERIES.md             # Prometheus & Loki Query-Beispiele
├── 📝 IMPLEMENTATION.md      # Implementierungs-Details
├── 🗂️ OVERVIEW.md            # Diese Datei
│
├── docker-compose.yml        # Haupt-Konfiguration
├── example.env               # Umgebungsvariablen-Template
├── .gitignore                # Git Ignore-Regeln
│
├── prometheus/
│   └── prometheus.yml        # Scrape-Targets & Retention
│
├── loki/
│   └── loki-config.yml       # Log-Storage & Retention (30d)
│
├── promtail/
│   └── promtail-config.yml   # Log-Sammlung (Access + App)
│
└── grafana/
    └── provisioning/
        ├── datasources/
        │   └── datasources.yml    # Auto-Config: Prometheus & Loki
        └── dashboards/
            └── dashboards.yml     # Dashboard-Provisioning
```

## 🚀 Schnellstart (3 Befehle)

```powershell
# 1. Netzwerk erstellen
docker network create monitoring

# 2. Stack starten
cd C:\Entwicklung\Container\monitoring
Copy-Item example.env .env
docker-compose up -d

# 3. Traefik neu starten
cd ..\traefik
docker-compose restart

# Fertig! Öffne http://localhost:3000 (admin/admin)
```

## 📊 Empfohlene Dashboards

Importiere diese in Grafana (Dashboards → Import):

| Dashboard | ID | Priorität |
|-----------|-----|-----------|
| **Traefik Official** | `17346` | ⭐⭐⭐ MUST-HAVE |
| Traefik Detailed | `11462` | ⭐⭐ Empfohlen |
| Loki Dashboard | `13639` | ⭐⭐ Empfohlen |

## 🔍 Was wird überwacht?

### ✅ Metriken (Prometheus → Traefik Port 8080)
- Request Rate & Throughput
- Response Times (Avg, P95, P99)
- HTTP Status Codes (2xx, 4xx, 5xx)
- Backend Health Status
- TLS-Zertifikat-Überwachung
- Traefik-interne Metriken

### ✅ Logs (Loki ← Promtail ← Traefik Log-Dateien)
- **Access Logs** (`access.log` → JSON)
  - Client IP, Method, Path
  - Status Code, Response Time
  - User Agent, Referrer
- **Application Logs** (`traefik.log` → JSON)
  - Fehler & Warnungen
  - Config-Änderungen
  - TLS-Events & Errors

### ✅ Retention
- **Prometheus**: 30 Tage Metriken
- **Loki**: 30 Tage Logs
- Anpassbar in den jeweiligen Config-Dateien

## 🎨 Features

- ✅ **Plug & Play**: Datasources werden automatisch konfiguriert
- ✅ **Auto-Discovery**: Neue Traefik-Services werden automatisch erkannt
- ✅ **JSON-Logs**: Strukturierte Logs für bessere Analyse
- ✅ **Labels**: Automatische Kategorisierung (job, type, method, status, level)
- ✅ **Skalierbar**: Einfach weitere Container hinzufügen
- ✅ **Ressourcenschonend**: Optimierte Retention-Zeiten
- ✅ **Traefik-Integration**: Bereits vorbereitet für HTTPS-Zugriff

## 📖 Dokumentation - Welche Datei wofür?

| Datei | Zweck | Wann lesen? |
|-------|-------|-------------|
| **QUICKSTART.md** | 3-Minuten Setup | 🔥 Beim ersten Start |
| **CHECKLIST.md** | Setup-Checkliste | ✅ Während Installation |
| **README.md** | Vollständige Doku | 📚 Für Details & Troubleshooting |
| **COMMANDS.md** | Befehlsreferenz | 🔧 Bei Problemen oder Updates |
| **QUERIES.md** | Query-Beispiele | 📊 Beim Erstellen eigener Dashboards |
| **IMPLEMENTATION.md** | Technische Details | 💡 Für Erweiterungen |
| **OVERVIEW.md** | Diese Übersicht | 🗺️ Für schnellen Überblick |

## 🔗 Wichtige URLs

| Service | URL | Beschreibung |
|---------|-----|--------------|
| **Grafana** | http://localhost:3000 | Hauptzugriff (Login: admin/admin) |
| Prometheus | http://localhost:9090 | Metriken & Targets |
| Prometheus Targets | http://localhost:9090/targets | Status der Scrape-Targets |
| Loki Ready Check | http://localhost:3100/ready | Loki Health Status |
| Traefik Metrics | http://localhost:8080/metrics | Raw Prometheus Metriken |
| Traefik Dashboard | http://localhost:8080 | Traefik UI |

## 🎯 Typische Anwendungsfälle

### 1. Request-Analyse
**Dashboard**: Traefik Official (ID: 17346)
- Requests pro Sekunde
- Response Times
- Error Rates

### 2. Fehlersuche
**Grafana Explore** → **Loki**
```logql
{job="traefik", type="access"} | json | status >= 500
```

### 3. Langsame Requests
**Grafana Explore** → **Loki**
```logql
{job="traefik", type="access"} | json | duration > 2000000000
```

### 4. IP-Analyse
**Grafana Explore** → **Loki**
```logql
topk(10, sum by (client_ip) (count_over_time({job="traefik", type="access"} | json [1h])))
```

### 5. Zertifikat-Überwachung
**Grafana Dashboard** → **Prometheus Query**
```promql
(traefik_tls_certs_not_after - time()) / 86400 < 30
```

## 🔧 Häufige Aufgaben

### Stack verwalten
```powershell
# Starten
docker-compose up -d

# Stoppen
docker-compose down

# Neu starten
docker-compose restart

# Logs anzeigen
docker-compose logs -f
```

### Konfiguration ändern
```powershell
# 1. Config-Datei bearbeiten (z.B. prometheus/prometheus.yml)
# 2. Prometheus neu laden
curl -X POST http://localhost:9090/-/reload
# ODER Container neu starten
docker-compose restart prometheus
```

### Weitere Container hinzufügen
1. Öffne `prometheus/prometheus.yml`
2. Füge neuen Job hinzu unter `scrape_configs:`
3. Optional: Füge Log-Sammlung in `promtail/promtail-config.yml` hinzu
4. Reload: `docker-compose restart prometheus promtail`

## 🛡️ Sicherheit

### ⚠️ WICHTIG vor Produktiv-Einsatz:
1. **Grafana-Passwort ändern** (in `.env` Datei)
2. **Traefik-Integration aktivieren** für HTTPS (siehe README.md)
3. **Firewall-Regeln** anpassen (Ports 3000, 9090, 3100)
4. **Backup-Strategie** definieren (siehe COMMANDS.md)

## 📈 Performance

### Ressourcen-Verbrauch (ca.)
- Prometheus: ~200 MB RAM, ~1 GB Disk/Monat
- Loki: ~150 MB RAM, ~500 MB Disk/Monat
- Grafana: ~100 MB RAM, ~50 MB Disk
- Promtail: ~50 MB RAM, minimal Disk

### Optimierung
- **Weniger Metriken**: Passe `scrape_interval` in prometheus.yml an (Standard: 15s)
- **Kürzere Retention**: Ändere Retention-Zeit (Standard: 30 Tage)
- **Log-Filtering**: Filtere unwichtige Logs in promtail-config.yml

## 🚨 Troubleshooting Quicklinks

| Problem | Lösung |
|---------|--------|
| Keine Metriken | `curl http://localhost:8080/metrics` → Traefik neu starten |
| Keine Logs | `docker logs promtail` → Log-Pfad prüfen |
| Grafana zeigt keine Daten | Datasources prüfen (automatisch konfiguriert) |
| Port bereits belegt | `netstat -ano \| Select-String ":3000"` |

Details: Siehe **README.md** → Troubleshooting-Sektion

## 📚 Weiterführende Links

- [Traefik Metrics Docs](https://doc.traefik.io/traefik/observability/metrics/prometheus/)
- [Grafana Dashboard Library](https://grafana.com/grafana/dashboards/)
- [Prometheus Query Language](https://prometheus.io/docs/prometheus/latest/querying/basics/)
- [Loki LogQL Docs](https://grafana.com/docs/loki/latest/logql/)

## 🎉 Fertig!

Du hast jetzt ein **vollständiges Monitoring-System** für Traefik!

**Nächste Schritte:**
1. ✅ Folge **QUICKSTART.md** für Installation
2. ✅ Importiere Dashboards (IDs: 17346, 11462, 13639)
3. ✅ Erkunde Grafana Explore-Modus
4. ✅ Erstelle eigene Dashboards mit **QUERIES.md**

**Bei Fragen:**
- Prüfe **README.md** für Details
- Nutze **COMMANDS.md** für Befehle
- Folge **CHECKLIST.md** für Setup-Schritte

Viel Erfolg! 🚀

