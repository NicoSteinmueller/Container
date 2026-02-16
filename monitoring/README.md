# Monitoring Stack - Traefik Überwachung

Zentrales Monitoring für Traefik mit Prometheus (Metriken) und Loki (Logs).

## 📦 Stack-Komponenten

- **Prometheus** (Port 9090): Metriken-Sammlung und Speicherung
- **Grafana** (Port 3000): Visualisierung von Metriken und Logs
- **Loki** (Port 3100): Log-Aggregation und -Speicherung  
- **Promtail**: Log-Shipper (liest Traefik-Logs und sendet sie an Loki)

## 🚀 Erste Schritte

### 1. Netzwerk erstellen (falls nicht vorhanden)
```powershell
docker network create monitoring
```

### 2. Environment-Variablen setzen
```powershell
Copy-Item example.env .env
# Passe .env an (Grafana Admin-Passwort ändern!)
```

### 3. Stack starten
```powershell
docker-compose up -d
```

### 4. Traefik neu starten (damit Prometheus-Metriken aktiv werden)
```powershell
cd ..\traefik
docker-compose restart
```

## 🎯 Zugriff

- **Grafana**: http://localhost:3000
  - User: `admin` (siehe .env)
  - Passwort: `admin` (siehe .env - ÄNDERN!)
  
- **Prometheus**: http://localhost:9090
- **Loki**: http://localhost:3100

## 📊 Dashboards importieren

Nach dem ersten Login in Grafana:

### Empfohlene Dashboards

1. **Traefik Official Dashboard**
   - ID: `17346`
   - Import: Dashboards → New → Import → ID eingeben
   - Datasource: Prometheus auswählen

2. **Traefik v2 Dashboard (funktioniert auch mit v3)**
   - ID: `11462`
   - Alternative mit mehr Details
   - Datasource: Prometheus

3. **Loki Dashboard (für Log-Analyse)**
   - ID: `13639`
   - Datasource: Loki

### Import-Anleitung
1. Grafana öffnen → Linkes Menü → Dashboards → New → Import
2. Dashboard-ID eingeben (z.B. `17346`)
3. Load klicken
4. Datasource auswählen (Prometheus/Loki)
5. Import klicken

## 📁 Verzeichnisstruktur

```
monitoring/
├── docker-compose.yml           # Haupt-Compose-Datei
├── example.env                  # Beispiel-Umgebungsvariablen
├── prometheus/
│   └── prometheus.yml           # Prometheus-Konfiguration (Scrape-Targets)
├── loki/
│   └── loki-config.yml          # Loki-Konfiguration (Log-Storage)
├── promtail/
│   └── promtail-config.yml      # Promtail-Konfiguration (Log-Sammlung)
└── grafana/
    └── provisioning/
        ├── datasources/
        │   └── datasources.yml  # Auto-Konfiguration von Prometheus & Loki
        └── dashboards/
            └── dashboards.yml   # Dashboard-Provisioning
```

## 🔍 Was wird überwacht?

### Metriken (Prometheus)
- HTTP Request Rate
- Response Times
- Status Codes (2xx, 4xx, 5xx)
- Backend-Health
- TLS-Zertifikate
- Traefik-interne Metriken

### Logs (Loki/Promtail)
- **Access Logs**: Alle HTTP-Requests mit Details (IP, Method, Path, Status, Duration)
- **Application Logs**: Traefik-interne Logs (Fehler, Warnungen, Config-Änderungen)

## 🔧 Anpassungen

### Weitere Container hinzufügen

**Prometheus** (`prometheus/prometheus.yml`):
```yaml
scrape_configs:
  - job_name: 'mein-service'
    static_configs:
      - targets: ['service-name:port']
```

**Promtail** (`promtail/promtail-config.yml`):
```yaml
scrape_configs:
  - job_name: mein-service-logs
    static_configs:
      - targets:
          - localhost
        labels:
          job: mein-service
          __path__: /var/log/mein-service/*.log
```

### Retention-Zeiten ändern

- **Prometheus**: `--storage.tsdb.retention.time=30d` in docker-compose.yml
- **Loki**: `retention_period: 30d` in loki-config.yml

## 🛟 Troubleshooting

### Prometheus zeigt keine Traefik-Metriken
```powershell
# Prüfe ob Traefik im monitoring-Netzwerk ist
docker inspect traefik -f '{{range $key, $value := .NetworkSettings.Networks}}{{$key}} {{end}}'

# Prüfe ob Metriken-Endpoint erreichbar ist
curl http://localhost:8080/metrics
```

### Loki zeigt keine Logs
```powershell
# Prüfe Promtail-Logs
docker logs promtail

# Prüfe ob Log-Dateien gemountet sind
docker exec promtail ls -la /var/log/traefik/
```

### Grafana Datasources nicht verfügbar
```powershell
# Container-Logs prüfen
docker logs grafana
docker logs prometheus
docker logs loki

# Verbindung testen
docker exec grafana wget -O- http://prometheus:9090/-/healthy
docker exec grafana wget -O- http://loki:3100/ready
```

## 📝 Wichtige Hinweise

- **Speicherplatz**: Prometheus/Loki sammeln Daten kontinuierlich. Retention-Zeit beachten!
- **Sicherheit**: Grafana-Admin-Passwort in `.env` ändern!
- **Traefik-Labels**: Für Produktiv-Umgebung Traefik-Authentifizierung für Grafana konfigurieren
- **Backup**: Die Docker-Volumes enthalten alle Daten (Metriken, Logs, Dashboards)

## 🔐 Produktiv-Setup (Optional)

Für Produktiv-Umgebungen Grafana hinter Traefik mit HTTPS absichern:

```yaml
# In monitoring/docker-compose.yml bei grafana labels:
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.grafana.rule=Host(`grafana.deinedomäne.de`)"
  - "traefik.http.routers.grafana.entrypoints=websecure"
  - "traefik.http.routers.grafana.tls.certresolver=letsencrypt"
  - "traefik.http.services.grafana.loadbalancer.server.port=3000"
  # Optional: Basic Auth Middleware hinzufügen
  - "traefik.http.routers.grafana.middlewares=auth@file"
```

## 📚 Weitere Ressourcen

- [Traefik Metrics Documentation](https://doc.traefik.io/traefik/observability/metrics/prometheus/)
- [Grafana Dashboards](https://grafana.com/grafana/dashboards/)
- [Loki Documentation](https://grafana.com/docs/loki/latest/)
- [Prometheus Query Language](https://prometheus.io/docs/prometheus/latest/querying/basics/)

