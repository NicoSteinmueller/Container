# Docker Container härten

## 1. Prinzip der geringsten Rechte
- User- und Gruppenrechte auf dem Host so einschränken
  - Unraid-Standard ist `99:100` (nobody:nogroup)
  - ```yaml 
    user: 99:100
    ```
- Read-only-Root-Dateisystem
  - ```yaml
    read_only: true
    ```
  - Vorher mit `docker diff` prüfen, welche Pfade Schreibzugriff benötigen (https://tmp.bearblog.dev/secure-filesystem-in-docker/)
  - `tmpfs`-Mounts für notwendige Schreibpfade
    - ```yaml
       tmpfs:
          - /tmp:rw,noexec,nosuid,size=64m
       ```
    - `rw` erlaubt Schreibzugriff
    - `noexec` verhindert die Ausführung von Binärdateien
    - `nosuid` blockiert das Setzen von SUID/SGID-Bits
    - `size` begrenzt den verfügbaren Speicherplatz (z.B. 64 MB für `/tmp`)
- Volumes und Bind-Mounts mit Bedacht einsetzen
  - Nur notwendige Pfade einhängen
  - Schreibrechte auf das Minimum beschränken
  - ```yaml
    volumes:
      - /host/appdata/myapp/config:/config:ro
      - /host/appdata/myapp/data:/data:rw
    ```

## 2. Capabilities und Privilegien
- Privilegierte Container vermeiden
  - ```yaml
    security_opt:
      - no-new-privileges:true
      - seccomp=default
    ```
  - Seccomp: Restrict syscalls to the minimum required for your container. Use Docker’s default seccomp profile as a starting point and customize per workload. Docker Seccomp 
  - AppArmor: Apply per-container AppArmor profiles to enforce mandatory access controls. Docker AppArmor 
  - SELinux: Enable SELinux on the host and ensure containers are labeled properly. Enforce SELinux policies to prevent unauthorized access to host resources. SELinux Guide for Docker

- Alle unnötigen Linux Capabilities entfernen
  - ```yaml
    cap_drop: ["ALL"]
    cap_add:
      - NET_BIND_SERVICE # für Reverse Proxies und DNS-Server
    ```
### Linux Capabilities – Referenz
https://dockerlabs.collabnix.com/advanced/security/capabilities/
https://man7.org/linux/man-pages/man7/capabilities.7.html

| Capability | Definition |
|---|---|
| `CHOWN` | Dateibezitzer und -gruppen willkürlich ändern |
| `DAC_OVERRIDE` | Datei-Zugriffsprüfungen umgehen (Lesen, Schreiben, Ausführung) |
| `FSETID` | SUID/SGID-Bits beim Ändern von Dateien nicht löschen |
| `FOWNER` | Eigentümerprüfungen bei Dateioperationen umgehen |
| `MKNOD` | Spezielle Dateien mit `mknod()` erstellen |
| `NET_RAW` | RAW und PACKET Sockets verwenden; für transparente Proxies |
| `SETGID` | Prozess-GID und Supplementären GID-Listen manipulieren |
| `SETUID` | Prozess-UID manipulieren; User-ID Mapping in User-Namespace schreiben |
| `SETFCAP` | Datei-Capabilities setzen |
| `SETPCAP` | Capabilities in Caller's Permitted Set hinzufügen/entfernen |
| `NET_BIND_SERVICE` | An privilegierte Ports < 1024 binden |
| `SYS_CHROOT` | `chroot()` verwenden zum Wechsel des Root-Directories |
| `KILL` | Signale ohne Prüfung an Prozesse senden |
| `AUDIT_WRITE` | In Kernel Audit Log schreiben |

# 3. Ressourcenbegrenzung
- CPU- und Speicherlimits setzen
  - Limits und Reservierungen **immer setzen**, ohne Ausnahme und auch in Dev Umgebungen.
  - Zum schauen, wo die Ressourcenfresser sind `docker stats` verwenden. 
  - ```yaml
    deploy:
      resources:
        limits:
          cpus: '1.5'    # Max 1,5 CPU-Cores
          memory: 512M   # Max 512 MB RAM
          pids: 256
        reservations:
          cpus: '0.5'    # Garantiert 0,5 Cores
          memory: 256M   # Garantiert 256 MB
    ```
    - `Cpus` begrenzt die max. benutzten CPU Kerne
    - `Memory` begrenzt den RAM-Verbrauch
    - `Pids` begrenzt die Anzahl der Prozesse/Threads im Container
- Logging begrenzen
  - ```yaml
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
    ```
- Ulimits setzen
  - https://docs.docker.com/reference/cli/docker/container/run/#set-ulimits-in-container---ulimit
  - ```yaml
    ulimits:
      nofile: 4096
    ```
  - `nofile` begrenzt die Anzahl offener Dateien/Sockets

# 4. Netzwerkisolation
- Nur notwendige Ports freigeben
  - ```yaml
    ports:
      - "80:80"
    ```
- Interne Netzwerke für die Kommunikation zwischen Containern nutzen
  - TODO
  - ```yaml
    networks:
        - app-network
    ```
  - internal: true
- Reverse Proxy für den Zugriff von außen verwenden
  - Nur den Reverse Proxy mit Host-Ports exponieren
  - App-Container nur im internen Netz erreichbar machen

# 5. Container Abhängigkeiten und Healthchecks
- immer Healthchecks definieren
  - ```yaml
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost/health"]
      interval: 30s
      timeout: 10s
      retries: 3
    ```
    - Erlaubt automatisches Neustarten bei Fehlern
    - ```yaml
        restart: on-failure:3
      ```
- `depends_on` mit healthcheck kombinieren
  - ```yaml
      depends_on:
        db:
          condition: service_healthy
    ```
    
# 6. Compose pro Umgebung
https://docs.docker.com/reference/compose-file/merge/
- **docker-compose.yml** (Basis): Gemeinsame Services, Images, Volumes, Netzwerke.
- **docker-compose.dev.yml** (Entwicklung): Volumes für Hot-Reload, Debug-Ports, lokale Builds.
- **docker-compose.prod.yml** (Produktion): Resource-Limits, Secrets, Restart-Policies, keine Dev-Volumes.
- **.env:** Variablen
```text
├── docker-compose.yml      # Basis: app + db
├── docker-compose.dev.yml  # Dev: Volumes + Ports
├── docker-compose.prod.yml # Prod: Limits + Secrets
└── .env                    # Variablen 
```
- **Überschreiben:** Gleiches Service-Feld → Letzte Datei gewinnt (z. B. die Ports in Dev überschreibt Basis).
- **Erweitern:** Neue Felder/Services werden hinzugefügt (z. B. Limits werden nur in Prod eingefügt).
```yaml
# Dev: Basis + Dev-Overrides
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d

# Prod: Basis + Prod-Overrides
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d

# Nur Basis (z. B. Test)
docker compose up -d
```
# 7. Allgemeine Best Practices
- `init: true` für ordnungsgemäße Signalbehandlung und Zombie-Vermeidung
- https://docs.docker.com/reference/compose-file/extension/#specifying-byte-values
- Specifying byte values:
  - 2b
  - 1024kb
  - 2048k
  - 300m
  - 1gb
- Specifying durations:
  - 10ms
  - 40s
  - 1m30s
  - 1h5m30s20ms