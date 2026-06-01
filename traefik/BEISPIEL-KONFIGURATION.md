# Beispiel: Nextcloud öffentlich, Immich lokal

## Nextcloud (öffentlich zugänglich)

In `nextcloud/docker-compose.yml` Labels hinzufügen:

```yaml
services:
  nextcloud:
    image: nextcloud:32.0.5-apache@sha256:aa9bb9bbde6e6afc756f7f101d65fbd57526165184737a85e31cc98dfbaaa2e2
    container_name: nextcloud
    restart: unless-stopped
    
    # Traefik Labels
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.nextcloud.rule=Host(`cloud.ihre-domain.de`)"
      - "traefik.http.routers.nextcloud.entrypoints=websecure"
      - "traefik.http.routers.nextcloud.tls.certresolver=letsencrypt"
      - "traefik.http.services.nextcloud.loadbalancer.server.port=80"
      
      # Optional: CalDAV/CardDAV Redirects
      - "traefik.http.middlewares.nextcloud-caldav.redirectregex.permanent=true"
      - "traefik.http.middlewares.nextcloud-caldav.redirectregex.regex=^https://(.*)/.well-known/(card|cal)dav"
      - "traefik.http.middlewares.nextcloud-caldav.redirectregex.replacement=https://$${1}/remote.php/dav/"
      - "traefik.http.routers.nextcloud.middlewares=nextcloud-caldav"
    
    # WICHTIG: Mit proxy Netzwerk verbinden
    networks:
      - nextcloud-network
      - proxy
    
    # ports können entfernt werden, da Traefik den Zugriff verwaltet
    # ports:
    #   - "38080:80"
    
    # ... rest der Konfiguration bleibt gleich ...

networks:
  nextcloud-network:
    name: nextcloud-network
  proxy:
    external: true  # Das proxy Netzwerk von Traefik
```

## Immich (nur lokal zugänglich)

In `immich/docker-compose.yml` Labels hinzufügen:

```yaml
services:
  immich-server:
    container_name: immich_server
    image: ghcr.io/immich-app/immich-server:v2.5.6@sha256:aa163d2e1cc2b16a9515dd1fef901e6f5231befad7024f093d7be1f2da14341a
    
    # Traefik Labels
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.immich.rule=Host(`photos.ihre-domain.de`)"
      - "traefik.http.routers.immich.entrypoints=websecure"
      - "traefik.http.routers.immich.tls.certresolver=letsencrypt"
      # WICHTIG: Middleware für lokale IP-Beschränkung
      - "traefik.http.routers.immich.middlewares=local-only"
      - "traefik.http.services.immich.loadbalancer.server.port=2283"
    
    # WICHTIG: Mit proxy Netzwerk verbinden
    networks:
      - default  # Internes Immich-Netzwerk
      - proxy    # Traefik proxy Netzwerk
    
    # ports können entfernt werden, da Traefik den Zugriff verwaltet
    # ports:
    #   - '34517:2283'
    
    # ... rest der Konfiguration bleibt gleich ...

networks:
  proxy:
    external: true  # Das proxy Netzwerk von Traefik
```

## DNS-Einstellungen

### Bei Ihrem DNS-Provider (z.B. Cloudflare)

Erstellen Sie A-Records für beide Domains:

```
cloud.ihre-domain.de    A    <Ihre öffentliche IP>
photos.ihre-domain.de   A    <Ihre öffentliche IP>
```

**Wichtig:** Beide müssen auf die gleiche IP zeigen, auch wenn Immich nur lokal erreichbar sein soll. Die Traefik `local-only` Middleware blockt externe Zugriffe.

### Optional: Lokale DNS-Überschreibung

Wenn Sie nicht möchten, dass der Traffic für lokale Services über Ihre öffentliche IP geht, können Sie in Ihrem lokalen DNS (z.B. Pi-hole, Router) eine Überschreibung erstellen:

```
photos.ihre-domain.de   A    192.168.x.x  (lokale IP Ihres Servers)
```

So bleibt der Traffic für Immich im lokalen Netzwerk.

## Firewall/Router-Konfiguration

### Port-Weiterleitungen (nur für öffentlichen Zugriff nötig)

```
Externe Port 80  → Server IP Port 80
Externe Port 443 → Server IP Port 443
```

## Zusammenfassung

### Was passiert bei einem externen Zugriff:

1. **Nextcloud (cloud.ihre-domain.de):**
   - ✅ Zugriff erlaubt
   - ✅ Let's Encrypt Zertifikat wird ausgestellt
   - ✅ Weiterleitung funktioniert

2. **Immich (photos.ihre-domain.de):**
   - ❌ Zugriff blockiert (IP nicht in Whitelist)
   - ✅ Let's Encrypt Zertifikat wird trotzdem ausgestellt (via DNS Challenge)
   - ❌ Benutzer sieht 403 Forbidden

### Was passiert bei einem lokalen Zugriff (z.B. 192.168.x.x):

1. **Nextcloud (cloud.ihre-domain.de):**
   - ✅ Zugriff erlaubt

2. **Immich (photos.ihre-domain.de):**
   - ✅ Zugriff erlaubt (IP in Whitelist)
   - ✅ Let's Encrypt Zertifikat funktioniert

## Testen

### Von extern (z.B. Mobilfunknetz):
```bash
curl -I https://cloud.ihre-domain.de
# Sollte 200 OK oder 301/302 Redirect zurückgeben

curl -I https://photos.ihre-domain.de
# Sollte 403 Forbidden zurückgeben
```

### Von lokal:
```bash
curl -I https://cloud.ihre-domain.de
# Sollte funktionieren

curl -I https://photos.ihre-domain.de
# Sollte ebenfalls funktionieren
```

## Nächste Schritte

1. ✅ DNS-Provider API-Credentials in `traefik/docker-compose.yml` eintragen
2. ✅ DNS-Provider in `traefik/config/traefik.yml` anpassen
3. ✅ Lokale IP-Bereiche in `traefik/config/traefik.yml` anpassen
4. ✅ Traefik neu starten: `docker-compose -f traefik/docker-compose.yml restart`
5. ✅ Services (Nextcloud, Immich) mit Labels erweitern
6. ✅ Services neu starten
7. ✅ Testen (lokal und extern)
8. ✅ Wenn alles funktioniert: Auf Let's Encrypt Production Server umstellen

