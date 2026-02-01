# Traefik Reverse Proxy

Moderne Reverse Proxy-Lösung mit automatischer SSL-Zertifikatsverwaltung und Service Discovery.

## 📋 Features

- ✅ **Automatisches SSL** - Let's Encrypt Integration (HTTP & DNS Challenge)
- ✅ **Docker Integration** - Automatische Service Discovery
- ✅ **Web Dashboard** - Übersichtliche Verwaltungsoberfläche
- ✅ **Security Headers** - Best-Practice Security-Konfiguration
- ✅ **HTTP/2 & HTTP/3** - Moderne Protokolle
- ✅ **Logging** - Strukturierte JSON-Logs
- ✅ **Middleware** - Compression, Rate Limiting, CORS, etc.

## 🚀 Schnellstart

### 1. Konfiguration anpassen

Bearbeite `traefik.yml` und ändere:
```yaml
certificatesResolvers:
  letsencrypt:
    acme:
      email: your-email@example.com  # <-- HIER DEINE E-MAIL EINTRAGEN
```

### 2. Dashboard-Passwort ändern

Generiere ein neues Passwort:
```powershell
# Methode 1: Mit Docker (empfohlen)
docker run --rm httpd:alpine htpasswd -nb admin IhrPasswort

# Methode 2: Mit htpasswd (falls installiert)
htpasswd -nb admin IhrPasswort
```

Ersetze in `docker-compose.yml` das Standard-Passwort:
```yaml
- "traefik.http.middlewares.traefik-auth.basicauth.users=admin:$$apr1$$..."
```

⚠️ **Wichtig**: In docker-compose.yml müssen `$`-Zeichen verdoppelt werden (`$$`).

### 3. Ordner erstellen

```powershell
# Im traefik-Verzeichnis
New-Item -ItemType Directory -Force letsencrypt, logs
```

### 4. acme.json erstellen und Rechte setzen (Linux/Mac)

```bash
touch letsencrypt/acme.json
chmod 600 letsencrypt/acme.json
```

Unter **Windows**: Die Datei wird automatisch beim ersten Start erstellt.

### 5. Starten

```powershell
docker-compose up -d
```

### 6. Dashboard aufrufen

- **Insecure (Development)**: http://localhost:8080
- **Secure**: https://traefik.localhost (mit BasicAuth)
  - User: `admin`
  - Passwort: siehe oben

## 🔧 Services anbinden

### Beispiel: Service mit Traefik Labels

```yaml
services:
  myapp:
    image: myapp:latest
    networks:
      - proxy  # Muss im proxy-Netzwerk sein!
    labels:
      # Traefik aktivieren
      - "traefik.enable=true"
      
      # Router-Konfiguration
      - "traefik.http.routers.myapp.rule=Host(`myapp.example.com`)"
      - "traefik.http.routers.myapp.entrypoints=websecure"
      
      # SSL mit Let's Encrypt
      - "traefik.http.routers.myapp.tls=true"
      - "traefik.http.routers.myapp.tls.certresolver=letsencrypt"
      
      # Service-Port (falls Container mehrere Ports hat)
      - "traefik.http.services.myapp.loadbalancer.server.port=8080"
      
      # Optional: Middlewares
      - "traefik.http.routers.myapp.middlewares=secureHeaders@file,compress@file"

networks:
  proxy:
    external: true
```

### Netzwerk für bestehende Services hinzufügen

```yaml
networks:
  default:
    # Internes Netzwerk
  proxy:
    external: true
    name: proxy
```

## 📝 Wichtige Konfigurationsdateien

| Datei | Beschreibung |
|-------|--------------|
| `docker-compose.yml` | Container-Definition |
| `traefik.yml` | Statische Konfiguration (EntryPoints, Provider, etc.) |
| `config.yml` | Dynamische Konfiguration (Middlewares, TLS-Optionen) |
| `letsencrypt/acme.json` | SSL-Zertifikate (wird automatisch erstellt) |
| `logs/traefik.log` | Traefik-Logs |
| `logs/access.log` | Access-Logs |

## 🌐 Let's Encrypt Konfiguration

### HTTP Challenge (Standard)

Funktioniert out-of-the-box, wenn Port 80 und 443 vom Internet erreichbar sind.

```yaml
certificatesResolvers:
  letsencrypt:
    acme:
      httpChallenge:
        entryPoint: web
```

### DNS Challenge (für Wildcard-Zertifikate)

Beispiel mit Cloudflare:

1. **Environment Variables setzen**:
   ```yaml
   environment:
     CF_API_EMAIL: your-email@example.com
     CF_DNS_API_TOKEN: your-cloudflare-token
   ```

2. **traefik.yml anpassen**:
   ```yaml
   certificatesResolvers:
     cloudflare:
       acme:
         dnsChallenge:
           provider: cloudflare
   ```

3. **In Services verwenden**:
   ```yaml
   - "traefik.http.routers.myapp.tls.certresolver=cloudflare"
   ```

Unterstützte DNS-Provider: https://doc.traefik.io/traefik/https/acme/#providers

## 🔒 Sicherheit

### Dashboard absichern

1. **BasicAuth** (Standard in dieser Config)
2. **IP Whitelist** aktivieren in `config.yml`:
   ```yaml
   middlewares:
     localOnly:
       ipWhiteList:
         sourceRange:
           - "192.168.1.0/24"
   ```

3. **Traefik-Router anpassen**:
   ```yaml
   - "traefik.http.routers.traefik.middlewares=traefik-auth,localOnly@file"
   ```

### Insecure Dashboard deaktivieren (Produktion)

In `traefik.yml`:
```yaml
api:
  dashboard: true
  insecure: false  # Port 8080 deaktivieren
```

Dann nur über HTTPS mit Labels erreichbar.

## 🛠️ Nützliche Befehle

```powershell
# Logs anzeigen
docker-compose logs -f traefik

# Neu starten
docker-compose restart traefik

# Konfiguration neu laden (bei Änderungen an config.yml)
docker-compose restart traefik

# Status prüfen
docker-compose ps

# Netzwerk anzeigen
docker network ls | Select-String proxy

# Zertifikate prüfen
docker exec traefik cat /letsencrypt/acme.json
```

## 📚 Middleware verwenden

Vordefinierte Middlewares aus `config.yml`:

| Middleware | Beschreibung |
|------------|--------------|
| `secureHeaders@file` | Security Headers (HSTS, XSS-Protection, etc.) |
| `compress@file` | Gzip/Brotli Kompression |
| `rateLimit@file` | Rate Limiting (100 req/s) |

Beispiel:
```yaml
- "traefik.http.routers.myapp.middlewares=secureHeaders@file,compress@file"
```

## 🐛 Troubleshooting

### Zertifikate werden nicht erstellt

1. Prüfe, ob Port 80/443 erreichbar sind
2. Prüfe E-Mail in `traefik.yml`
3. Verwende Staging-Server für Tests:
   ```yaml
   caServer: https://acme-staging-v02.api.letsencrypt.org/directory
   ```
4. Lösche `letsencrypt/acme.json` und starte neu

### Service nicht erreichbar

1. Ist der Service im `proxy`-Netzwerk?
2. Ist `traefik.enable=true` gesetzt?
3. Ist der richtige Port konfiguriert?
4. Prüfe Dashboard: http://localhost:8080

### Logs prüfen

```powershell
# Live-Logs
docker-compose logs -f traefik

# Access-Logs
Get-Content logs/access.log -Tail 50

# Traefik-Logs
Get-Content logs/traefik.log -Tail 50
```

## 🔗 Weiterführende Links

- **Offizielle Dokumentation**: https://doc.traefik.io/traefik/
- **Docker Provider**: https://doc.traefik.io/traefik/providers/docker/
- **Let's Encrypt**: https://doc.traefik.io/traefik/https/acme/
- **Middlewares**: https://doc.traefik.io/traefik/middlewares/overview/

## 📊 Monitoring (Optional)

Prometheus-Metrics aktivieren in `traefik.yml`:

```yaml
metrics:
  prometheus:
    entryPoint: metrics

entryPoints:
  metrics:
    address: ":8082"
```

Dann in docker-compose.yml Port hinzufügen:
```yaml
ports:
  - "8082:8082"
```

Metrics abrufbar unter: http://localhost:8082/metrics

## 📦 Updates

Aktualisiere das Image in `docker-compose.yml`:

```powershell
docker-compose pull
docker-compose up -d
```

⚠️ **Hinweis**: Vor Updates immer `letsencrypt/acme.json` sichern!

---

**Version**: Traefik v3.2  
**Stand**: Februar 2026
