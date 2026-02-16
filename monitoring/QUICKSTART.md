# 🚀 Schnellstart - Monitoring Stack

## Setup in 3 Minuten

### 1. Netzwerk erstellen
```powershell
docker network create monitoring
```

### 2. Monitoring-Stack starten
```powershell
cd C:\Entwicklung\Container\monitoring
Copy-Item example.env .env
docker-compose up -d
```

### 3. Traefik neu starten (aktiviert Metriken)
```powershell
cd ..\traefik
docker-compose restart
```

### 4. Grafana öffnen
Browser: http://localhost:3000
- User: `admin`
- Passwort: `admin`

### 5. Dashboards importieren
1. Links: **Dashboards** → **New** → **Import**
2. Dashboard-IDs eingeben und importieren:

| Dashboard | ID | Beschreibung |
|-----------|-----|-------------|
| Traefik Official | `17346` | Haupt-Dashboard für Traefik v3 |
| Traefik Detailed | `11462` | Detaillierte Metriken |
| Loki Logs | `13639` | Log-Analyse |

3. Bei jedem Import: Datasource auswählen (Prometheus/Loki)

## ✅ Fertig!

Du hast jetzt:
- ✅ Echtzeit-Metriken von Traefik
- ✅ Log-Analyse (Access + Application Logs)
- ✅ 30 Tage Daten-Retention
- ✅ Automatische Datasource-Konfiguration

## 🔍 Erste Checks

### Prometheus-Metriken prüfen
```powershell
# Traefik Metriken abrufen
curl http://localhost:8080/metrics
```

### Logs prüfen
In Grafana: **Explore** → Datasource: **Loki** → Query: `{job="traefik"}`

### Status prüfen
```powershell
docker ps | Select-String "prometheus|grafana|loki|promtail"
```

Alle Container sollten "Up" sein.

