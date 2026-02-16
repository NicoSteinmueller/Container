# 🐳 Docker Container Repository

Dieses Repository enthält Docker-Compose-Konfigurationen für selbst-gehostete Services mit automatischen Updates durch Renovate.

## 📦 Services

| Service | Beschreibung | Port | Konfiguration |
|---------|--------------|------|---------------|
| **[Traefik](traefik/)** | Reverse Proxy & Load Balancer | 80, 443, 8080 | [docker-compose.yml](traefik/docker-compose.yml) |
| **[Monitoring](monitoring/)** | Prometheus + Grafana + Loki Stack | 3000, 9090 | [docker-compose.yml](monitoring/docker-compose.yml) |
| **[Backrest](backrest/)** | Backup-Tool mit Web-UI für Restic | 9898 | [docker-compose.yml](backrest/docker-compose.yml) |
| **[Immich](immich/)** | Foto- und Video-Backup-Lösung | 34517 | [docker-compose.yml](immich/docker-compose.yml) |
| **[Keycloak](keycloak/)** | Identity & Access Management | 61348 | [docker-compose.yml](keycloak/docker-compose.yml) |
| **[Kopia](kopia/)** | Schnelles Backup-Tool | 51515 | [docker-compose.yml](kopia/docker-compose.yml) |

## 🔄 Automatische Updates mit Renovate

**Renovate** hält alle Docker-Images automatisch aktuell:
- ✅ Tägliche Prüfung
- ✅ Automatische Pull Requests für Updates
- ✅ Automerge für Patch-Updates
- ✅ Security-Updates werden priorisiert
- ✅ Dependency Dashboard

**📖 [RENOVATE.md](RENOVATE.md)** - Vollständige Installations- und Konfigurationsanleitung

## 🔧 Konfiguration

Jeder Service hat seine eigene `docker-compose.yml` Datei mit:
- ⚙️ Umgebungsvariablen
- 📁 Volume-Mappings
- 🌐 Port-Konfigurationen
- 🔄 Restart-Policies

Siehe die jeweiligen Service-Verzeichnisse für spezifische Konfigurationen.
