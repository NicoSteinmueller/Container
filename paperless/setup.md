# Paperless-ngx mit Keycloak SSO

## Architektur-Übersicht

```
┌─────────────────────────────────────────────────────────────┐
│                    Geteilte Services                        │
│  ┌──────────────┐              ┌──────────────┐             │
│  │  Gotenberg   │              │     Tika     │             │
│  │ (PDF-Konv.)  │              │    (OCR)     │             │
│  └──────────────┘              └──────────────┘             │
│           paperless_shared Network                          │
└─────────────────────────────────────────────────────────────┘
                           ▲
                           │ (verwendet von allen Instanzen)
                           │
        ┌──────────────────┴──────────────────┐
        │                                     │
┌───────▼────────┐                  ┌────────▼────────┐
│  Instanz: main │                  │ Instanz: privat │
│                │                  │                 │
│  Paperless     │                  │  Paperless      │
│  PostgreSQL    │                  │  PostgreSQL     │
│  Redis         │                  │  Redis          │
│                │                  │                 │
│  Port: 61349   │                  │  Port: 61350    │
└────────────────┘                  └─────────────────┘
```

## Deployment-Reihenfolge

### 1️⃣ Geteilte Services deployen (EINMALIG)

**Stack-Name:** `paperless-shared`  
**Datei:** `docker-compose.shared.yml`

- **Gotenberg**: PDF-Konvertierung
- **Tika**: OCR und Dokumentenanalyse


### 2️⃣ Instanzen deployen

**Stack-Name:** `paperless-main`  
**Datei:** `docker-compose.yml`

- **Paperless**: Hauptanwendung
- **PostgreSQL**: Datenbank
- **Redis**: Cache

**Environment Variables:**

| Variable | Default | Beschreibung |
|----------|---------|-------------|
| `INSTANCE_NAME` | `main` | Eindeutiger Name für diese Instanz |
| `INSTANCE_PORT` | `61349` | Externer Port für diese Instanz |
| `PAPERLESS_ADMIN_USER` | `admin` | Admin-Benutzername |
| `PAPERLESS_ADMIN_PASSWORD` | `changeme` | Admin-Passwort |
| `PAPERLESS_SECRET_KEY` | - | Django Secret Key |
| `DB_PASSWORD` | `changeme` | Datenbank-Passwort |

**Environment Variables Beispiel:**

```env
# === INSTANZ-KONFIGURATION ===
INSTANCE_NAME=main
INSTANCE_PORT=61349

# === SICHERHEIT ===
DB_PASSWORD=<sicheres-passwort>
PAPERLESS_SECRET_KEY=<mindestens-50-zeichen-alphanumerisch-mit-sonderzeichen>

# === PATH-ROUTING (für Subpath hinter Reverse Proxy) ===
PAPERLESS_URL=https://docs.example.com
PAPERLESS_SUBPATH=/paperless-main
PAPERLESS_ALLOWED_HOSTS=docs.example.com

# === KEYCLOAK SSO ===
PAPERLESS_APPS=allauth.socialaccount.providers.openid_connect
KEYCLOAK_CONFIG={"openid_connect":{"APPS":[{"provider_id":"keycloak","name":"Keycloak","client_id":"paperless-main","secret":"SECRET_MAIN","settings":{"server_url":"https://keycloak.example.com/realms/homelab/.well-known/openid-configuration"}}]}}
PAPERLESS_ALLOW_SIGNUPS=false
PAPERLESS_DISABLE_REGULAR_LOGIN=true

# === HOST PATH MOUNTS ===
PAPERLESS_DATA_BASE_PATH=/mnt/paperless
```

**Wichtig für Subpath-Deployment:**
- `PAPERLESS_URL` enthält die Basis-URL **OHNE** Subpath
- `PAPERLESS_SUBPATH` enthält den Pfad (z.B. `/paperless-main`)
- Die vollständige URL ist dann: `https://docs.example.com/paperless-main`

## Ports & URLs

| Instanz | Port  | Container-Name | Subpath | Vollständige URL |
|---------|-------|----------------|---------|------------------|
| main    | 61349 | paperless_main | /paperless-main | https://docs.example.com/paperless-main |
| privat  | 61350 | paperless_privat | /paperless-privat | https://docs.example.com/paperless-privat |
| firma   | 61351 | paperless_firma | /paperless-firma | https://docs.example.com/paperless-firma |
| kunde1  | 61352 | paperless_kunde1 | /paperless-kunde1 | https://docs.example.com/paperless-kunde1 |

## 🌐 Nginx Proxy Manager Konfiguration

**Wichtig:** Bei Subpath-Deployment brauchst du **keinen** Proxy Host für die Root-Domain (`https://docs.example.com`).
Stattdessen erstellst du **einen Proxy Host pro Instanz**, die jeweils auf ihren eigenen Subpath hören.

**Architektur:**
- Alle Instanzen auf **einer Domain** mit verschiedenen Pfaden
- Beispiel: `https://docs.example.com/paperless-main`, `https://docs.example.com/paperless-privat`
- Nur **eine Domain** und **ein SSL-Zertifikat** nötig


### Proxy Host für jede Instanz einrichten:

#### Beispiel: Instanz "main"

**Details Tab:**
- **Domain Names:** `docs.example.com`
- **Scheme:** `http`
- **Forward Hostname / IP:** `<IP-deines-Docker-Hosts>`
- **Forward Port:** `61349`
- **Cache Assets:** ✓ aktivieren
- **Block Common Explopts:** ✓ aktivieren
- **Websockets Support:** ✓ aktivieren

**Custom locations → Add location:**
- **Location:** `/paperless-main`
- **Scheme:** `http`
- **Forward Hostname / IP:** `<IP-deines-Docker-Hosts>`
- **Forward Port:** `61349`
- **Websockets Support:** ✓ aktivieren

**Advanced Tab:**
```nginx
# Für /paperless-main Location
location /paperless-main {
    proxy_pass http://<IP-deines-Docker-Hosts>:61349;
    
    # Proxy Headers
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Port $server_port;
    
    # Websockets
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    
    # Upload-Größe für Dokumente
    client_max_body_size 100M;
    
    # Timeouts
    proxy_read_timeout 300;
    proxy_connect_timeout 300;
    proxy_send_timeout 300;
}
```

#### Wiederhole für weitere Instanzen:

**Instanz "privat":**
- Neuer Proxy Host mit Location: `/paperless-privat`
- Forward Port: `61350`
- Gleiche Domain: `docs.example.com`

**Instanz "firma":**
- Neuer Proxy Host mit Location: `/paperless-firma`
- Forward Port: `61351`
- Gleiche Domain: `docs.example.com`

---

### ⚠️ Was passiert bei Aufruf von `https://docs.example.com/` (ohne Subpath)?

**Aktuell:** Du bekommst eine **404-Fehlerseite**, da kein Proxy Host für die Root-Domain (`/`) konfiguriert ist.

**Empfohlene Lösung:** Erstelle eine einfache Landing Page mit Links zu allen Instanzen.

#### Option 1: Nginx Custom HTML (empfohlen für einfache Lösung)

Erstelle einen **zusätzlichen Proxy Host** in NPM für die Root-Domain:

**Details Tab:**
- **Domain Names:** `docs.example.com`
- **Scheme:** `http`
- **Forward Hostname / IP:** `127.0.0.1`
- **Forward Port:** `80`

**Custom Locations → Add location:**
- **Location:** `/`
- **Definition:**
  ```nginx
  location = / {
      default_type text/html;
      return 200 '
  <!DOCTYPE html>
  <html>
  <head>
      <title>Paperless Übersicht</title>
      <meta charset="utf-8">
      <style>
          body { 
              font-family: Arial, sans-serif; 
              max-width: 600px; 
              margin: 100px auto; 
              padding: 20px;
              background: #f5f5f5;
          }
          h1 { color: #333; text-align: center; }
          .container { background: white; padding: 30px; border-radius: 10px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
          a { 
              display: block; 
              padding: 15px; 
              margin: 10px 0; 
              background: #007bff; 
              color: white; 
              text-decoration: none; 
              border-radius: 5px; 
              text-align: center;
              transition: background 0.3s;
          }
          a:hover { background: #0056b3; }
      </style>
  </head>
  <body>
      <div class="container">
          <h1>📄 Paperless Instanzen</h1>
          <a href="/paperless-main">Main Instanz →</a>
          <a href="/paperless-privat">Privat Instanz →</a>
          <a href="/paperless-firma">Firma Instanz →</a>
      </div>
  </body>
  </html>
      ';
  }
  ```

**Wichtig:** Dieser Proxy Host muss die **niedrigste Priorität** haben, damit die Subpath-Locations Vorrang haben!

#### Option 2: Umleitung zur Haupt-Instanz

Wenn du immer direkt zu `/paperless-main` weitergeleitet werden möchtest:

**Custom Location für `/`:**
```nginx
location = / {
    return 302 /paperless-main;
}
```

#### Option 3: Statische Landing Page mit Docker (für erweiterte Designs)

Deploye einen einfachen Nginx-Container mit einer Landing Page:

```yaml
# landing-page-compose.yml
services:
  landing-page:
    image: nginx:alpine
    container_name: paperless_landing
    volumes:
      - ./landing/index.html:/usr/share/nginx/html/index.html:ro
    ports:
      - "8080:80"
    restart: unless-stopped
```

Dann in NPM:
- **Location:** `/`
- **Forward Hostname/IP:** `<Docker-Host-IP>`
- **Forward Port:** `8080`

---

## 🔐 Single Sign-On (SSO) mit Keycloak
Paperless-ngx unterstützt **OpenID Connect (OIDC)** für Single Sign-On mit Keycloak.

**Gruppen-basierte Zugriffskontrolle**

Jede Paperless-Instanz bekommt eine eigene Gruppe in Keycloak, und nur Mitglieder dieser Gruppe dürfen sich anmelden.

### Client erstellen

1. Gehe zu **Clients** → **Create client**
2. **General Settings:**
   - Client type: `OpenID Connect`
   - Client ID: `paperless` (oder beliebig, notieren!)
   - Name: `Paperless-ngx`
   - Klicke **Next**

3. **Capability config:**
   - Client authentication: `ON` ✅
   - Authorization: `OFF`
   - Standard flow: `ON` ✅
   - Direct access grants: `OFF`
   - Klicke **Next**

4. **Login settings:**
   - Root URL: `https://docs.example.com/paperless-main`
   - Valid redirect URIs: `https://docs.example.com/paperless-main/accounts/oidc/keycloak/login/callback/`
   - Valid post logout redirect URIs: `https://docs.example.com/paperless-main/`
   - Web origins: `https://docs.example.com`
   - Klicke **Save**
   
   **Wichtig bei Subpath-Deployment:** Alle URIs müssen den Subpath enthalten!

### 1️⃣ Gruppen in Keycloak erstellen

1. Gehe zu deinem Realm (z.B. `homelab`)
2. **Groups** → **Create group**

Erstelle folgende Gruppen:

| Gruppe | Beschreibung |
|--------|--------------|
| `paperless-main-users` | Zugriff auf Main-Instanz |
| `paperless-firma-users` | Zugriff auf Firma-Instanz |
| `paperless-privat-users` | Zugriff auf Private-Instanz |
| `paperless-admins` | Admins mit Zugriff auf ALLE Instanzen |

### 2️⃣ Benutzer zu Gruppen hinzufügen

**Beispiel-Struktur:**

```
Gruppen:
├─ paperless-admins
│  └─ admin (dein Account)
│
├─ paperless-main-users
│  └─ admin (zusätzlich)
│
├─ paperless-firma-users
│  ├─ admin (zusätzlich)
│  └─ user_firma
│
└─ paperless-privat-users
   ├─ admin (zusätzlich)
   └─ user_privat
```

**So fügst du Benutzer zu Gruppen hinzu:**

1. **Users** → Benutzer auswählen
2. Tab **Groups** → **Join Group**
3. Gruppe auswählen (z.B. `paperless-firma-users`)
4. **Join**

### 3️⃣ Client Scope für Gruppen erstellen

#### A) Client Scope erstellen

1. **Client Scopes** → **Create client scope**
2. **Settings:**
    - Name: `groups`
    - Type: `Default`
    - Protocol: `OpenID Connect`
    - Display on consent screen: `OFF`
3. **Save**

#### B) Group Mapper hinzufügen

1. Gehe zum neuen Client Scope `groups`
2. Tab **Mappers** → **Add mapper** → **By configuration**
3. Wähle: **Group Membership**
4. **Konfiguration:**
   ```
   Name: groups
   Token Claim Name: groups
   Full group path: OFF
   Add to ID token: ON
   Add to access token: ON
   Add to userinfo: ON
   ```
5. **Save**

#### C) Client Scope zu allen Clients hinzufügen

Für **jeden Client** (`paperless-main`, `paperless-firma`, `paperless-privat`):

1. Gehe zu **Clients** → Client auswählen
2. Tab **Client scopes** → **Add client scope**
3. Wähle `groups` → **Add** → **Default**

### 4️⃣ Client Policy konfigurieren (Zugriffsbeschränkung)

Jetzt kommt der wichtigste Teil: **Authorization** aktivieren und Zugriff beschränken!

#### Für Client: paperless-main

1. **Clients** → `paperless-main`
2. **Settings Tab:**
    - Client authentication: `ON` ✅
    - Authorization: `ON` ✅ (neu aktivieren!)
3. **Save**

4. **Tab: Authorization** → **Policies** → **Create policy**
5. **Policy type:** `Group`
6. **Settings:**
   ```
   Name: paperless-main-access
   Groups: /paperless-main-users ODER /paperless-admins
   Logic: Positive
   ```
7. **Save**

8. **Tab: Authorization** → **Permissions** → **Create permission**
9. **Permission type:** `Resource-based`
10. **Settings:**
    ```
    Name: paperless-main-permission
    Apply policy: paperless-main-access
    Decision strategy: Affirmative
    ```
11. **Save**

### Conditional Authentication Flow

1. **Authentication** → **Flows** → **Copy** (von "browser")
2. Name: `browser-with-group-check`
3. **Add execution** → **Condition - User in Group**
4. **Konfiguration:**
    - Für Client `paperless-main`: Group = `paperless-main-users` oder `paperless-admins`
    - Aktion: `DENY` wenn nicht in Gruppe

**Problem:** Dies gilt für ALLE Clients im Realm.


## 🔐 Admin-Rechte vergeben (für jede Instanz)

Nach dem ersten Login über Keycloak:

### Option A: Django Shell (empfohlen)

```bash
# Instanz: main
docker exec -it paperless_main python3 manage.py shell
```

```python
from django.contrib.auth.models import User
user = User.objects.get(username='admin')  # Dein Keycloak-Username
user.is_staff = True
user.is_superuser = True
user.save()
exit()
```
oder

```phython
python manage.py createsuperuser
```

Wiederholen für:
```bash
docker exec -it paperless_firma python3 manage.py shell
docker exec -it paperless_privat python3 manage.py shell
```

### Option B: Django Admin Interface

1. Login mit lokalem Admin-Account (fallback)
2. Gehe zu: `https://docs.example.com/paperless-main/admin/`
3. Users → Keycloak-User auswählen
4. ✅ Staff status
5. ✅ Superuser status
6. Save

# Dokument Export und Import
## Exportieren von Dokumenten
```shell
docker exec -it paperless_main document_exporter ../export --use-folder-prefix --zip
```

## Importieren von Dokumenten
```shell
docker exec -it paperless_main document_importer ../export/export.zip
```