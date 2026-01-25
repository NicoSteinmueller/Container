# MinIO - Self-hosted S3-kompatibler Object Storage

MinIO ist ein hochperformanter, S3-kompatibler Object Storage Server, der selbst gehostet werden kann.

## Features

- ✅ Vollständig S3-API kompatibel
- ✅ Einfache Installation mit Docker
- ✅ Web-basierte Management-Konsole
- ✅ Multi-Tenancy Support
- ✅ Verschlüsselung und Sicherheit
- ✅ Versioning und Lifecycle-Policies
- ✅ Event-Notifications

## Installation & Start

```bash
# Container starten
docker compose up -d

# Logs anzeigen
docker compose logs -f

# Container stoppen
docker compose down
```

## Zugriff

Nach dem Start ist MinIO verfügbar unter:

- **API Endpoint**: http://localhost:9000
- **Web Console**: http://localhost:9001

### Standard-Zugangsdaten

⚠️ **WICHTIG**: Diese sollten vor dem Produktiveinsatz geändert werden!

- **Benutzername**: `admin`
- **Passwort**: `changeme123`

## Zugangsdaten ändern

Bearbeite die `docker-compose.yml` und ändere:

```yaml
environment:
  MINIO_ROOT_USER: dein_benutzername
  MINIO_ROOT_PASSWORD: dein_sicheres_passwort
```

Danach Container neu starten:
```bash
docker compose down
docker compose up -d
```

## Verwendung

### 1. Web-Console

Die einfachste Methode ist die Web-Console unter http://localhost:9001:
- Buckets erstellen und verwalten
- Dateien hoch- und herunterladen
- Access Keys erstellen
- Policies konfigurieren

### 2. MinIO Client (mc)

```bash
# Installation
wget https://dl.min.io/client/mc/release/linux-amd64/mc
chmod +x mc
sudo mv mc /usr/local/bin/

# Konfiguration
mc alias set myminio http://localhost:9000 admin changeme123

# Bucket erstellen
mc mb myminio/mybucket

# Datei hochladen
mc cp myfile.txt myminio/mybucket/

# Dateien auflisten
mc ls myminio/mybucket/
```

### 3. AWS CLI

MinIO ist vollständig kompatibel mit der AWS CLI:

```bash
# Installation (falls noch nicht installiert)
pip install awscli

# Konfiguration
aws configure --profile minio
# AWS Access Key ID: admin
# AWS Secret Access Key: changeme123
# Default region: us-east-1
# Default output format: json

# Verwendung
aws --profile minio --endpoint-url http://localhost:9000 s3 ls
aws --profile minio --endpoint-url http://localhost:9000 s3 mb s3://mybucket
aws --profile minio --endpoint-url http://localhost:9000 s3 cp file.txt s3://mybucket/
```

### 4. Python (boto3)

```python
import boto3

# S3 Client erstellen
s3 = boto3.client('s3',
    endpoint_url='http://localhost:9000',
    aws_access_key_id='admin',
    aws_secret_access_key='changeme123'
)

# Bucket erstellen
s3.create_bucket(Bucket='mybucket')

# Datei hochladen
s3.upload_file('local_file.txt', 'mybucket', 'remote_file.txt')

# Datei herunterladen
s3.download_file('mybucket', 'remote_file.txt', 'downloaded_file.txt')
```

## Access Keys erstellen

Für Anwendungen solltest du separate Access Keys erstellen (nicht die Root-Credentials verwenden):

1. Öffne die Web-Console (http://localhost:9001)
2. Gehe zu **Identity** → **Service Accounts**
3. Klicke auf **Create Service Account**
4. Speichere Access Key und Secret Key sicher

## Buckets und Policies

### Bucket öffentlich machen

```bash
# Mit mc Client
mc anonymous set download myminio/public-bucket

# Oder über die Web-Console: Bucket → Manage → Access Policy
```

### Custom Policy erstellen

In der Web-Console unter **Identity** → **Policies** kannst du benutzerdefinierte Policies erstellen.

## Backup & Restore

### Daten sichern

Die MinIO-Daten liegen im `./data` Verzeichnis. Sichere dieses regelmäßig:

```bash
# Backup erstellen
tar -czf minio-backup-$(date +%Y%m%d).tar.gz ./data

# Oder mit rsync
rsync -av ./data/ /backup/minio-data/
```

### Daten wiederherstellen

```bash
# Container stoppen
docker compose down

# Daten wiederherstellen
tar -xzf minio-backup-YYYYMMDD.tar.gz

# Container starten
docker compose up -d
```

## Integration mit anderen Services

### Backrest Integration

MinIO kann als Backup-Ziel für Backrest verwendet werden:

```yaml
# In Backrest Repo-Konfiguration
repo:
  uri: s3:http://localhost:9000/backrest-backups
  env:
    AWS_ACCESS_KEY_ID: your_access_key
    AWS_SECRET_ACCESS_KEY: your_secret_key
```

### Immich Integration

Immich kann MinIO als externen Storage nutzen. Siehe Immich-Dokumentation für Details.

## Erweiterte Konfiguration

### HTTPS aktivieren

Für Produktivumgebungen solltest du HTTPS verwenden. Platziere Zertifikate in:
- `./certs/public.crt`
- `./certs/private.key`

Und passe die docker-compose.yml an:

```yaml
volumes:
  - ./data:/data
  - ./certs:/root/.minio/certs
```

### MinIO hinter Nginx (Reverse Proxy)

**✅ Ja, es ist sicher MinIO hinter Nginx zu betreiben** - sogar empfohlen für Production!

#### Vorteile von Nginx als Reverse Proxy:

- ✅ **TLS/SSL Terminierung**: Nginx handled HTTPS, MinIO läuft intern mit HTTP
- ✅ **Rate Limiting**: Schutz vor DDoS und Brute-Force
- ✅ **Authentifizierung**: Zusätzliche Auth-Layer möglich
- ✅ **Load Balancing**: Traffic auf mehrere MinIO-Instanzen verteilen
- ✅ **Caching**: Statische Inhalte cachen
- ✅ **IP Whitelisting**: Zugriff nur von bestimmten IPs

#### Beispiel Nginx-Konfiguration

```nginx
# /etc/nginx/sites-available/minio

upstream minio_api {
    server localhost:9000;
}

upstream minio_console {
    server localhost:9001;
}

# API Server (S3-Endpoint)
server {
    listen 443 ssl http2;
    server_name s3.example.com;

    # TLS-Konfiguration
    ssl_certificate /etc/letsencrypt/live/s3.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/s3.example.com/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    # Security Headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;

    # Datei-Upload-Größe (wichtig für große Objekte!)
    client_max_body_size 0;  # Unbegrenzt
    
    # Timeouts für große Uploads
    proxy_connect_timeout 300;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    chunked_transfer_encoding off;

    # Rate Limiting (optional)
    limit_req_zone $binary_remote_addr zone=minio_limit:10m rate=10r/s;
    limit_req zone=minio_limit burst=20 nodelay;

    location / {
        proxy_pass http://minio_api;
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # Für S3-Signaturen wichtig
        proxy_set_header X-NginX-Proxy true;
    }
}

# Web Console
server {
    listen 443 ssl http2;
    server_name minio-console.example.com;

    ssl_certificate /etc/letsencrypt/live/minio-console.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/minio-console.example.com/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    # Security Headers
    add_header Strict-Transport-Security "max-age=31536000" always;
    
    # IP Whitelisting (optional - nur für Admin-Zugriff)
    # allow 192.168.1.0/24;  # Lokales Netzwerk
    # allow 1.2.3.4;         # Admin-IP
    # deny all;

    location / {
        proxy_pass http://minio_console;
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # WebSocket Support (für Live-Updates in Console)
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}

# HTTP -> HTTPS Redirect
server {
    listen 80;
    server_name s3.example.com minio-console.example.com;
    return 301 https://$host$request_uri;
}
```

#### Docker-Compose Anpassung für Nginx

```yaml
# docker-compose.yml
services:
  minio:
    # ...existing config...
    ports:
      # Nur localhost binden, nicht nach außen!
      - "127.0.0.1:9000:9000"
      - "127.0.0.1:9001:9001"
    environment:
      # Browser redirect URL für Console
      MINIO_BROWSER_REDIRECT_URL: "https://minio-console.example.com"
      MINIO_SERVER_URL: "https://s3.example.com"
```

#### Sicherheits-Best-Practices

1. **Starke Root-Credentials**
   ```bash
   # Generiere sichere Credentials
   MINIO_ROOT_USER=$(openssl rand -base64 32)
   MINIO_ROOT_PASSWORD=$(openssl rand -base64 48)
   ```

2. **Firewall-Regeln**
   ```bash
   # Nur Nginx kann auf MinIO zugreifen
   ufw deny 9000
   ufw deny 9001
   ufw allow 80/tcp
   ufw allow 443/tcp
   ```

3. **Fail2Ban für Nginx**
   ```ini
   # /etc/fail2ban/filter.d/nginx-minio.conf
   [Definition]
   failregex = ^<HOST> .* "(GET|POST|HEAD).*" 401
   ignoreregex =
   ```

4. **Monitoring & Logging**
   - Aktiviere Nginx Access Logs
   - Überwache MinIO Audit Logs
   - Nutze Prometheus für Metriken

5. **Regelmäßige Updates**
   - MinIO-Container regelmäßig updaten
   - Nginx aktuell halten
   - SSL-Zertifikate auto-renew (Let's Encrypt)

#### Testen der Konfiguration

```bash
# Nginx Config testen
sudo nginx -t

# Nginx neu laden
sudo systemctl reload nginx

# Test mit AWS CLI
aws --endpoint-url https://s3.example.com s3 ls

# Test mit curl
curl -I https://s3.example.com
```

### Distributed Mode (Multi-Server)

Für High Availability kannst du MinIO im distributed mode betreiben. Siehe [MinIO Dokumentation](https://min.io/docs/minio/linux/operations/install-deploy-manage/deploy-minio-multi-node-multi-drive.html).

## Troubleshooting

### Container startet nicht

```bash
# Logs prüfen
docker compose logs minio

# Berechtigungen prüfen
ls -la ./data
```

### Port bereits belegt

Falls Port 9000 oder 9001 bereits verwendet wird, ändere in docker-compose.yml:

```yaml
ports:
  - "9002:9000"  # API auf lokalem Port 9002
  - "9003:9001"  # Console auf lokalem Port 9003
```

## Monitoring

MinIO bietet Prometheus-Metriken unter:
- http://localhost:9000/minio/v2/metrics/cluster

## Weitere Ressourcen

- [Offizielle MinIO Dokumentation](https://min.io/docs/minio/linux/index.html)
- [MinIO Client Dokumentation](https://min.io/docs/minio/linux/reference/minio-mc.html)
- [S3 API Kompatibilität](https://min.io/docs/minio/linux/integrations/aws-cli-with-minio.html)

## Alternative Lösungen

Falls MinIO nicht deinen Anforderungen entspricht (z.B. weil die Benutzerverwaltung primär über CLI erfolgt), gibt es weitere Alternativen:

### ⭐ Mit besserer UI für Benutzerverwaltung

#### **Nextcloud S3** 
- ✅ Vollständige Benutzerverwaltung über Web-UI
- ✅ Rechteverwaltung, Gruppen, Quotas alles per GUI
- ✅ Integrierte Collaboration-Features
- ⚠️ Schwerer als reine S3-Lösungen
- 🔗 S3-API über `files_external` App oder Nextcloud als S3-Frontend

#### **SeaweedFS**
- ✅ Web-UI für Monitoring und Basis-Verwaltung
- ✅ Sehr schnell und einfacher als MinIO
- ✅ Automatisches Tiering und Caching
- ⚠️ Benutzerverwaltung ebenfalls eingeschränkter als Nextcloud
- 🔗 [https://github.com/seaweedfs/seaweedfs](https://github.com/seaweedfs/seaweedfs)

#### **LocalStack (für Entwicklung)**
- ✅ Vollständige AWS-Emulation inkl. IAM
- ✅ Web-UI für alle AWS-Services
- ⚠️ Primär für Testing/Development, nicht Production
- 💰 Pro-Version für erweiterte Features
- 🔗 [https://localstack.cloud](https://localstack.cloud)

### 🏢 Enterprise/Komplexere Lösungen

#### **Ceph mit Dashboard**
- ✅ Professionelles Web-Dashboard (Ceph Dashboard)
- ✅ Umfassende Verwaltung: User, Buckets, Pools, Performance
- ✅ RGW (RADOS Gateway) für S3-Kompatibilität
- ⚠️ Sehr komplex, benötigt mehrere Nodes für HA
- 🎯 Ideal für große Deployments
- 🔗 [https://docs.ceph.com/](https://docs.ceph.com/)

#### **Cloudian HyperStore**
- ✅ Enterprise S3-Storage mit vollständiger Web-UI
- ✅ Multi-Tenancy, QoS, Monitoring
- 💰 Kommerzielle Lösung
- 🎯 Für große Unternehmen

### 🔧 Leichtgewichtige Alternativen

#### **Garage**
- ✅ Geo-distributed Storage
- ✅ Sehr einfach zu betreiben
- ⚠️ Benutzerverwaltung hauptsächlich CLI
- 🎯 Ideal für Self-Hosting über mehrere Standorte
- 🔗 [https://garagehq.deuxfleurs.fr/](https://garagehq.deuxfleurs.fr/)

#### **Zenko CloudServer**
- ✅ Multi-Cloud Gateway mit Management-UI
- ✅ S3-API Frontend für verschiedene Backends
- 🔗 [https://www.zenko.io/](https://www.zenko.io/)

### 💡 Empfehlung je nach Use-Case

| Use-Case | Empfehlung | Grund |
|----------|------------|-------|
| **Vollständige UI-Verwaltung gewünscht** | Nextcloud oder Ceph Dashboard | Beste Web-basierte Admin-Oberfläche |
| **Performance & Einfachheit** | SeaweedFS | Schnell, weniger Overhead als MinIO |
| **Entwicklung/Testing** | LocalStack | Vollständige AWS-Emulation |
| **Production, aber simpel** | MinIO + mc CLI | Beste S3-Kompatibilität, stabiler |
| **Geo-Distributed** | Garage | Für verteilte Standorte optimiert |
| **Enterprise mit Budget** | Ceph | Professionell, skalierbar, umfassendes Dashboard |

### 📝 Hinweis zu MinIO UI

MinIO's Web-Console bietet **teilweise** UI-Verwaltung:
- ✅ Buckets, Objekte, Monitoring: volle UI-Unterstützung
- ✅ Service Accounts (Access Keys): können über UI erstellt werden
- ⚠️ Benutzer & IAM-Policies: primär über `mc` CLI
- ⚠️ LDAP/OIDC-Integration möglich für externe User-Verwaltung

**Wenn du MinIO nutzen möchtest, aber UI-Verwaltung brauchst:**
1. Integriere ein externes Identity Provider (Keycloak, LDAP)
2. Nutze den `mc` CLI für initiale IAM-Konfiguration
3. Danach können Benutzer sich über IdP einloggen
