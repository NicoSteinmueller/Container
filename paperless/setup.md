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

TODO Mapping für consume und export
```env
# === PATH-ROUTING ===
PAPERLESS_URL=https://docs.example.com/paperless-main
PAPERLESS_FORCE_SCRIPT_NAME=/paperless-main
PAPERLESS_STATIC_URL=/paperless-main/static/

# === KEYCLOAK ===
PAPERLESS_APPS=allauth.socialaccount.providers.openid_connect
KEYCLOAK_CONFIG={"openid_connect":{"APPS":[{"provider_id":"keycloak","name":"Keycloak","client_id":"paperless-main","secret":"SECRET_MAIN","settings":{"server_url":"https://keycloak.example.com/realms/homelab/.well-known/openid-configuration"}}]}}
```
## Ports

| Instanz | Empfohlener Port | Container-Name | Subpath |
|---------|-----------------|----------------|---------|
| main    | 61349          | paperless_main |         |
| privat  | 61350          | paperless_privat | privat  |
| firma   | 61351          | paperless_firma | firma   |
| kunde1  | 61352          | paperless_kunde1 | kunde1  |
| ...     | ...            | ... |         |


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
   - Root URL: `https://paperless.deine-domain.de`
   - Valid redirect URIs: `https://paperless.deine-domain.de/accounts/oidc/keycloak/login/callback/`
   - Valid post logout redirect URIs: `https://paperless.deine-domain.de/`
   - Web origins: `https://paperless.deine-domain.de`
   - Klicke **Save**

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