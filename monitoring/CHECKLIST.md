# ✅ Setup-Checkliste

## Vor dem Start

- [ ] Docker läuft
- [ ] Docker Compose installiert
- [ ] Traefik läuft und ist konfiguriert

## Installation

- [x] Monitoring-Verzeichnis erstellt (`C:\Entwicklung\Container\monitoring`)
- [x] Alle Konfigurationsdateien erstellt
- [x] Traefik-Konfiguration für Metriken angepasst
- [ ] `.env` Datei erstellt (von `example.env` kopieren)
- [ ] Grafana Admin-Passwort in `.env` angepasst

## Netzwerk

- [ ] `monitoring` Netzwerk erstellt: `docker network create monitoring`
- [ ] Traefik ist im `monitoring` Netzwerk (bereits in docker-compose.yml)

## Services starten

- [ ] Monitoring Stack gestartet: `docker-compose up -d`
- [ ] Alle 4 Container laufen: `docker-compose ps`
- [ ] Traefik neu gestartet: `cd ..\traefik && docker-compose restart`

## Verifikation

- [ ] Grafana erreichbar: http://localhost:3000
- [ ] Prometheus erreichbar: http://localhost:9090
- [ ] Prometheus zeigt Traefik als Target: http://localhost:9090/targets
- [ ] Traefik Metriken verfügbar: http://localhost:8080/metrics
- [ ] Loki erreichbar: http://localhost:3100/ready

## Grafana konfigurieren

- [ ] Bei Grafana eingeloggt (admin/admin)
- [ ] Passwort geändert
- [ ] Datasources funktionieren (automatisch konfiguriert)
  - [ ] Prometheus: http://prometheus:9090
  - [ ] Loki: http://loki:3100

## Dashboards importieren

- [ ] **Traefik Official** (ID: 17346) importiert
- [ ] **Traefik Detailed** (ID: 11462) importiert (optional)
- [ ] **Loki Dashboard** (ID: 13639) importiert
- [ ] Alle Dashboards zeigen Daten

## Tests

- [ ] Metriken werden gesammelt
  - [ ] Grafana Explore → Prometheus → Query: `traefik_entrypoint_requests_total`
- [ ] Logs werden gesammelt
  - [ ] Grafana Explore → Loki → Query: `{job="traefik"}`
- [ ] Access Logs sichtbar
  - [ ] Query: `{job="traefik", type="access"}`
- [ ] Application Logs sichtbar
  - [ ] Query: `{job="traefik", type="application"}`

## Optional: Produktiv-Setup

- [ ] Grafana hinter Traefik mit HTTPS
- [ ] Authentifizierung für Grafana aktiviert
- [ ] Firewall-Regeln angepasst
- [ ] Backup-Strategie definiert
- [ ] Alerts konfiguriert

## Dokumentation gelesen

- [ ] README.md durchgelesen
- [ ] QUICKSTART.md befolgt
- [ ] QUERIES.md angeschaut
- [ ] COMMANDS.md als Referenz gespeichert

## Fertig! 🎉

Das Monitoring-System ist jetzt einsatzbereit und überwacht:
- ✅ Traefik Request Rate
- ✅ Response Times
- ✅ Status Codes
- ✅ Access Logs
- ✅ Application Logs
- ✅ 30 Tage Daten-Retention

## Nächste Schritte

1. **Explore nutzen**: Teste verschiedene Queries in Grafana Explore
2. **Alerts einrichten**: Konfiguriere Benachrichtigungen für kritische Events
3. **Custom Dashboards**: Erstelle eigene Dashboards für spezifische Bedürfnisse
4. **Weitere Container**: Erweitere das Monitoring auf andere Services
5. **Backup-Routine**: Richte regelmäßige Backups der Volumes ein

## Bei Problemen

1. Prüfe `COMMANDS.md` für Troubleshooting-Befehle
2. Schaue in die Container-Logs: `docker-compose logs`
3. Prüfe README.md → Troubleshooting-Sektion
4. Validiere Konfiguration: `docker-compose config`

## Wichtige Notizen

- **Default Retention**: 30 Tage (anpassbar in prometheus.yml und loki-config.yml)
- **Disk Space**: Überwache den verfügbaren Speicherplatz für Volumes
- **Performance**: Bei vielen Requests evtl. Scrape-Interval anpassen
- **Sicherheit**: Ändere Grafana-Passwort in Produktion!

