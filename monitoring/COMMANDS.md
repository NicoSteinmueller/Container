# 🔧 Monitoring Stack - Wichtige Befehle

## 🚀 Start & Stop

```powershell
# Netzwerk erstellen (einmalig)
docker network create monitoring

# Stack starten
cd C:\Entwicklung\Container\monitoring
docker-compose up -d

# Stack stoppen
docker-compose down

# Stack stoppen + Volumes löschen (alle Daten!)
docker-compose down -v

# Traefik neu starten (nach Config-Änderung)
cd ..\traefik
docker-compose restart
```

## 📊 Status prüfen

```powershell
# Alle Container anzeigen
docker-compose ps

# Logs anzeigen
docker-compose logs -f              # Alle Services
docker-compose logs -f prometheus   # Nur Prometheus
docker-compose logs -f grafana      # Nur Grafana
docker-compose logs -f loki         # Nur Loki
docker-compose logs -f promtail     # Nur Promtail

# Letzte 50 Zeilen
docker logs prometheus --tail 50
docker logs grafana --tail 50
```

## 🔍 Tests & Debugging

```powershell
# Traefik Metriken abrufen
curl http://localhost:8080/metrics

# Prometheus Targets prüfen
curl http://localhost:9090/api/v1/targets

# Loki Health Check
curl http://localhost:3100/ready

# Loki Query testen
curl "http://localhost:3100/loki/api/v1/query?query={job=\"traefik\"}" | ConvertFrom-Json

# Promtail Positions prüfen (welche Logs wurden gelesen)
docker exec promtail cat /tmp/positions.yaml

# Log-Dateien im Container prüfen
docker exec promtail ls -la /var/log/traefik/
```

## 🔄 Updates

```powershell
# Images aktualisieren
docker-compose pull

# Container neu erstellen mit neuen Images
docker-compose up -d --force-recreate

# Einzelnen Service neu starten
docker-compose restart prometheus
docker-compose restart grafana
```

## 🛠️ Konfiguration neu laden

```powershell
# Prometheus Config neu laden (ohne Neustart)
curl -X POST http://localhost:9090/-/reload

# Grafana provisioning neu laden
docker-compose restart grafana

# Loki Config neu laden
docker-compose restart loki

# Promtail Config neu laden
docker-compose restart promtail
```

## 📦 Volumes & Daten

```powershell
# Volumes anzeigen
docker volume ls | Select-String "monitoring"

# Volume-Details
docker volume inspect monitoring_prometheus-data
docker volume inspect monitoring_loki-data
docker volume inspect monitoring_grafana-data

# Disk-Usage prüfen
docker system df -v | Select-String "monitoring"

# Backup erstellen (Beispiel für Grafana)
docker run --rm -v monitoring_grafana-data:/data -v ${PWD}:/backup alpine tar czf /backup/grafana-backup.tar.gz /data
```

## 🧹 Cleanup & Wartung

```powershell
# Container neu starten (bei Problemen)
docker-compose restart

# Logs leeren (wenn zu groß)
docker-compose down
Remove-Item C:\Entwicklung\Container\traefik\logs\*.log
docker-compose up -d

# Alte Daten bereinigen (Prometheus)
# Automatisch nach 30 Tagen (siehe retention.time)

# Ungenutzte Docker-Ressourcen löschen
docker system prune -a
```

## 🔐 Sicherheit

```powershell
# Grafana Admin-Passwort zurücksetzen
docker exec -it grafana grafana-cli admin reset-admin-password neupasswort123

# .env Datei erstellen/bearbeiten
Copy-Item example.env .env
notepad .env
```

## 📈 Performance & Monitoring

```powershell
# Container Ressourcen-Nutzung
docker stats prometheus grafana loki promtail

# Prometheus TSDB Stats
curl http://localhost:9090/api/v1/status/tsdb-status | ConvertFrom-Json | ConvertTo-Json -Depth 10

# Loki Stats
curl http://localhost:3100/metrics | Select-String "loki_"
```

## 🔧 Troubleshooting

```powershell
# Container ist nicht im Netzwerk?
docker network inspect monitoring

# Port bereits belegt?
netstat -ano | Select-String ":3000|:9090|:3100"

# Config-Syntax prüfen
docker-compose config

# Einzelnen Container interaktiv starten
docker run -it --rm prom/prometheus:v3.2.0 sh
docker run -it --rm grafana/grafana:11.5.1 sh

# In laufenden Container einsteigen
docker exec -it grafana sh
docker exec -it prometheus sh
```

## 🌐 URLs

```powershell
# Services öffnen (PowerShell)
Start-Process "http://localhost:3000"  # Grafana
Start-Process "http://localhost:9090"  # Prometheus
Start-Process "http://localhost:3100"  # Loki (nur API)
Start-Process "http://localhost:8080"  # Traefik Dashboard
```

## 📤 Export & Backup

```powershell
# Grafana Dashboard exportieren
# Via UI: Dashboard Settings → JSON Model → Copy JSON

# Prometheus Daten exportieren (Snapshot)
docker run --rm -v monitoring_prometheus-data:/prometheus -v ${PWD}:/backup prom/prometheus:v3.2.0 /bin/promtool tsdb dump /prometheus > prometheus-dump.txt

# Komplettes Backup aller Volumes
docker-compose down
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
docker run --rm -v monitoring_prometheus-data:/prometheus -v ${PWD}:/backup alpine tar czf /backup/backup-prometheus-$timestamp.tar.gz /prometheus
docker run --rm -v monitoring_loki-data:/loki -v ${PWD}:/backup alpine tar czf /backup/backup-loki-$timestamp.tar.gz /loki
docker run --rm -v monitoring_grafana-data:/grafana -v ${PWD}:/backup alpine tar czf /backup/backup-grafana-$timestamp.tar.gz /grafana
docker-compose up -d
```

## 🔄 Restore

```powershell
# Grafana-Backup wiederherstellen
docker-compose down
docker run --rm -v monitoring_grafana-data:/data -v ${PWD}:/backup alpine sh -c "rm -rf /data/* && tar xzf /backup/grafana-backup.tar.gz -C /"
docker-compose up -d
```

## 📊 Quick Checks

```powershell
# Alles läuft?
docker ps | Select-String "prometheus|grafana|loki|promtail" | Measure-Object
# Sollte 4 Container zeigen

# Metriken werden gesammelt?
curl http://localhost:9090/api/v1/query?query=traefik_entrypoint_requests_total | ConvertFrom-Json | Select-Object -ExpandProperty data | Select-Object -ExpandProperty result | Measure-Object
# Sollte > 0 Results zeigen

# Logs werden gesammelt?
curl "http://localhost:3100/loki/api/v1/query?query={job=\"traefik\"}" | ConvertFrom-Json | Select-Object -ExpandProperty data | Select-Object -ExpandProperty result | Measure-Object
# Sollte > 0 Results zeigen
```

## 💡 Nützliche Aliases (Optional)

```powershell
# In PowerShell Profile ($PROFILE) hinzufügen:
function mon-up { cd C:\Entwicklung\Container\monitoring; docker-compose up -d }
function mon-down { cd C:\Entwicklung\Container\monitoring; docker-compose down }
function mon-logs { cd C:\Entwicklung\Container\monitoring; docker-compose logs -f }
function mon-ps { cd C:\Entwicklung\Container\monitoring; docker-compose ps }
function mon-restart { cd C:\Entwicklung\Container\monitoring; docker-compose restart }
```

