# Traefik Konfigurations-Übersicht

## Struktur

Die Traefik-Konfiguration ist in **statische** und **dynamische** Teile aufgeteilt:

### Statische Konfiguration (`traefik.yml`)
Wird beim Start von Traefik geladen. Änderungen erfordern einen Neustart.

**Enthält:**
- ✅ Global Settings (checkNewVersion, sendAnonymousUsage)
- ✅ API & Dashboard Settings
- ✅ Providers (Docker, File)
- ✅ Certificate Resolvers (Let's Encrypt)
- ✅ EntryPoints (Ports: 80, 443, 88)
- ✅ Logging & Access Logs
- ✅ Metrics & Tracing (optional)
- ✅ Experimental Features & Plugins

### Dynamische Konfiguration (`config/dynamic/`)
Wird zur Laufzeit geladen. Änderungen werden automatisch erkannt (Hot Reload).

**Enthält:**

#### `middlewares.yml`
- 🌐 **local-only** - IP Allow List (127.0.0.1/32, 192.168.178.0/16)
- 🔒 **secure-headers** - Security Headers (HSTS, XSS Protection, Frame Deny, etc.)
- 🔗 **secure-local-only** - Chain: secure-headers + local-only
- ⏱️ **rate-limit** - Rate Limiting (100 req/s average, burst: 50)
- 📦 **compress** - Kompression aktiviert
- 🔐 **basic-auth** - Basic Auth (auskommentiert, Beispiel)

#### `routers.yml`
- Router-Definitionen für Services ohne Docker Provider
- Beispiel für Traefik Dashboard Router (auskommentiert, Beispiel)

#### `tls.yml`
- 🔐 **modern** - TLS 1.3 only, Curves: P521/P384
- 🔐 **intermediate** - TLS 1.2+, Best-Practice Cipher Suites
- 🔐 **default** - TLS 1.2+, sniStrict: false

## Verwendung

### In Docker Compose

```yaml
services:
  myapp:
    image: myapp:latest
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.myapp.rule=Host(`myapp.example.com`)"
      - "traefik.http.routers.myapp.entrypoints=websecure"
      - "traefik.http.routers.myapp.tls.certresolver=letsencrypt"
      - "traefik.http.routers.myapp.tls.options=intermediate@file"
      - "traefik.http.routers.myapp.middlewares=secure-headers@file,compress@file"
    networks:
      - proxy
```

### Wichtige Hinweise

1. **@file Suffix**: Wenn Middlewares/TLS aus dynamischer Config verwendet werden, muss `@file` angehängt werden
2. **Hot Reload**: Dynamische Config wird automatisch neu geladen
3. **Validierung**: YAML-Schema validiert die Syntax automatisch

## Volume Mappings für Docker

Stelle sicher, dass im `docker-compose.yml` folgendes gemappt ist:

```yaml
volumes:
  - ./config:/config:ro
  - ./logs:/logs
  - letsencrypt:/letsencrypt
```

## Weitere Informationen

- [Traefik v3 Dokumentation](https://doc.traefik.io/traefik/v3.0/)
- [Dynamische Konfiguration](https://doc.traefik.io/traefik/v3.0/providers/file/)
- [Middlewares](https://doc.traefik.io/traefik/v3.0/middlewares/overview/)
- [TLS Optionen](https://doc.traefik.io/traefik/v3.0/https/tls/)

