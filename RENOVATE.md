# 🔄 Renovate - Automatische Docker-Updates

Renovate hält Ihre Docker-Images automatisch aktuell und erstellt Pull/Merge Requests für Updates.

## 📋 Inhaltsverzeichnis

- [Übersicht](#übersicht)
- [Quick-Start](#quick-start)
- [GitHub Installation](#github-installation)
- [Konfiguration](#konfiguration)
- [Verwendung](#verwendung)
- [Troubleshooting](#troubleshooting)

---

## 🎯 Übersicht

### Was macht Renovate?

Renovate überwacht automatisch:
- ✅ Docker-Images in allen `docker-compose.yml` Dateien
- ✅ Neue Versionen und Security-Updates
- ✅ Erstellt Pull/Merge Requests für Updates
- ✅ Pinnt Digest-Hashes (SHA256) für Reproduzierbarkeit

### Überwachte Services

- **Backrest** (`backrest/docker-compose.yml`) - Port 9898
- **Immich** (`immich/docker-compose.yml`) - Port 34517
- **Keycloak** (`keycloak/docker-compose.yml`) - Port 61348
- **Kopia** (`kopia/docker-compose.yml`) - Port 51515

### Zeitplan

- **Täglich**: 02:00 - 06:00 Uhr
- **Zeitzone**: Europe/Berlin

### Features

- ✅ Automatisches Mergen von Patch-Updates
- ✅ Manuelle Review für Minor- und Major-Updates
- ✅ Ein separater PR pro docker-compose.yml Datei
- ✅ Automatische Review-Anfrage an Code Owners
- ✅ Digest-Hashes (SHA256) für Reproduzierbarkeit
- ✅ Dependency Dashboard
- ✅ Semantic Commit Messages

### Update-Strategie

- **Patch** (1.2.3 → 1.2.4): PR erstellt und automatisch gemergt
- **Minor** (1.2.0 → 1.3.0): PR erstellt, manuelle Review erforderlich
- **Major** (1.x → 2.x): PR erstellt, manuelle Review erforderlich

---

## 🚀 Quick-Start

### GitHub (5 Minuten)

**Variante A: GitHub App (Empfohlen)**

1. ✅ Öffnen Sie https://github.com/apps/renovate
2. ✅ Klicken Sie auf **"Install"**
3. ✅ Wählen Sie Ihr Repository aus
4. ✅ Committen Sie die Konfiguration:
   ```bash
   git add renovate.json
   git commit -m "chore: add Renovate configuration"
   git push origin main
   ```
5. ✅ Warten Sie auf den Onboarding-PR
6. ✅ Mergen Sie den PR → **Fertig!**

**Variante B: GitHub Actions**

1. Token erstellen: https://github.com/settings/tokens (Scopes: `repo`, `workflow`)
2. Als Secret hinzufügen: Repository → Settings → Secrets → `RENOVATE_TOKEN`
3. Committen:
   ```bash
   git add .github/workflows/renovate.yml renovate.json
   git commit -m "ci: add Renovate workflow"
   git push origin main
   ```
4. Testen: Actions → Renovate → "Run workflow"

### Nach der Installation

- [ ] Dependency Dashboard ansehen (wird als Issue erstellt)
- [ ] Ersten Update-PR überprüfen
- [ ] Optional: `renovate.json` anpassen

---

## 🐙 GitHub Installation

### Methode 1: GitHub App (Empfohlen)

Die einfachste Methode für GitHub-Repositories.

**Schritt 1: App installieren**

1. Gehen Sie zu: https://github.com/apps/renovate
2. Klicken Sie auf **"Install"**
3. Wählen Sie Account/Organisation
4. Wählen Sie:
   - **All repositories** oder
   - **Only select repositories**
5. Klicken Sie auf **"Install"**

**Schritt 2: Konfiguration committen**

```bash
git add renovate.json
git commit -m "chore: add Renovate configuration"
git push origin main
```

**Schritt 3: Onboarding-PR**

1. Renovate erstellt automatisch einen Onboarding-PR
2. Überprüfen Sie die Konfiguration
3. Mergen Sie den PR → Renovate ist aktiv!

### Methode 2: GitHub Actions (Self-Hosted)

Für mehr Kontrolle oder Self-Hosted Runner.

**Schritt 1: Personal Access Token**

1. Gehen Sie zu: https://github.com/settings/tokens
2. **"Generate new token (classic)"**
3. Name: "Renovate Bot"
4. Scopes: `repo`, `workflow`
5. Token kopieren

**Schritt 2: Token als Secret**

1. Repository → **Settings** → **Secrets and variables** → **Actions**
2. **"New repository secret"**
3. Name: `RENOVATE_TOKEN`
4. Value: Ihr Token

**Schritt 3: Workflow testen**

1. **Actions** → **Renovate**
2. **"Run workflow"**
3. Logs überprüfen

Die Workflow-Datei `.github/workflows/renovate.yml` ist bereits vorhanden und läuft täglich um 2:00 Uhr.

---


## ⚙️ Konfiguration

Die `renovate.json` im Repository ist vorkonfiguriert.

### Haupt-Einstellungen

```json
{
  "schedule": [
    "after 2am and before 6am every day"
  ],
  "timezone": "Europe/Berlin",
  "docker": {
    "enabled": true,
    "pinDigests": true
  },
  "automerge": false,
  "platformAutomerge": true
}
```

### Paket-Regeln

- **Patch-Updates**: Automatisch gemergt nach CI-Tests
- **Digest-Updates**: Automatisch gemergt nach CI-Tests
- **Minor-Updates**: PR pro docker-compose.yml Datei, manuelle Review
- **Major-Updates**: PR pro docker-compose.yml Datei, manuelle Review

### Datei-spezifische Branches

Jede docker-compose.yml bekommt eigene PRs mit Prefixen:
- **Backrest**: `renovate/backrest-*`
- **Immich**: `renovate/immich-*`
- **Keycloak**: `renovate/keycloak-*`
- **Kopia**: `renovate/kopia-*`

### Anpassen

**Zeitplan ändern:**

```json
"schedule": ["before 5am on monday"]
```

Weitere Beispiele:
- `"every weekend"` - Nur am Wochenende
- `"after 10pm every weekday"` - Werktags nach 22 Uhr
- `"before 5am"` - Täglich vor 5 Uhr

**Automerge deaktivieren:**

```json
"packageRules": [{
  "matchUpdateTypes": ["patch", "digest"],
  "automerge": false
}]
```

**Images ignorieren:**

```json
"ignoreDeps": [
  "kopia/kopia",
  "postgres"
]
```

**PR-Limits:**

```json
"prConcurrentLimit": 10,
"prHourlyLimit": 5
```

### Alternative Konfiguration

Die Datei `.renovaterc.json5` enthält die gleiche Konfiguration mit ausführlichen Kommentaren. Umbenennen zu `renovate.json5` zum Verwenden.

---

## 🚀 Verwendung

### Dependency Dashboard

Nach der Aktivierung erstellt Renovate ein Issue:
- 📋 Alle ausstehenden Updates
- ✅ Erfolgreich gemergete Updates
- ⏸️ Pausierte Updates
- 🔒 Security-Probleme

### Updates überprüfen

1. Renovate erstellt automatisch PRs
2. Überprüfen Sie Änderungen
3. Testen Sie bei Bedarf lokal:
   ```bash
   git fetch
   git checkout renovate/immich-2.x
   docker-compose pull
   docker-compose up -d
   ```
4. Mergen oder schließen

### Manuell ausführen

Actions → Renovate → "Run workflow"

### Logs überprüfen

1. Actions → Renovate Workflow
2. Lauf auswählen
3. Logs expandieren


### Docker-Compose validieren

Lokal testen:
```bash
./validate-compose.sh
```

Einzelne Datei:
```bash
cd immich
docker-compose config
```

---

## 🆘 Troubleshooting

### GitHub

**Problem: Keine PRs werden erstellt**

Lösungen:
1. App-Berechtigungen prüfen: https://github.com/settings/installations
2. `renovate.json` im Root-Verzeichnis?
3. GitHub Actions Logs prüfen
4. Konfiguration validieren: https://docs.renovatebot.com/config-validator/

**Problem: "Rate limit exceeded"**

Lösung:
```json
"prHourlyLimit": 1,
"prConcurrentLimit": 2
```

**Problem: Token-Fehler**

1. Token-Scopes prüfen: `repo`, `workflow`
2. Token noch gültig?
3. Secret richtig benannt: `RENOVATE_TOKEN`


### Allgemein

**Konfiguration validieren:**
```bash
# Online:
https://docs.renovatebot.com/config-validator/

# Lokal (erfordert npm):
npm install -g renovate
renovate-config-validator
```

**Docker-Compose Fehler:**
```bash
./validate-compose.sh
```

**Renovate ignoriert Updates:**
1. Dependency Dashboard ansehen
2. "Rejected" oder "Pending" Status?
3. `ignoreDeps` in `renovate.json` prüfen
4. Logs auf Fehlermeldungen prüfen

---

## 📚 Weitere Ressourcen

### Dokumentation

- **Renovate Docs**: https://docs.renovatebot.com/
- **Configuration Options**: https://docs.renovatebot.com/configuration-options/
- **Docker Manager**: https://docs.renovatebot.com/docker/
- **Preset Configs**: https://docs.renovatebot.com/presets-config/

### Support

- **GitHub Discussions**: https://github.com/renovatebot/renovate/discussions
- **GitHub App**: https://github.com/apps/renovate

### Lokale Dateien

- `renovate.json` - Aktive Konfiguration
- `.renovaterc.json5` - Alternative Config mit Kommentaren
- `.github/workflows/renovate.yml` - GitHub Actions
- `validate-compose.sh` - Validierungs-Skript

---

## 📝 Best Practices

1. **Testen Sie Updates**: Auch mit Automerge, testen Sie kritische Updates
2. **Branch Protection**: Erfordern Sie CI-Tests vor dem Mergen
3. **Monitoring**: Behalten Sie das Dependency Dashboard im Auge
4. **Regelmäßige Reviews**: Überprüfen Sie wöchentlich ausstehende Updates
5. **Staging**: Testen Sie Major-Updates in Test-Umgebung
6. **Rollback-Plan**: Plan für Probleme nach Updates
7. **Passwörter ändern**: Alle Default-Passwörter in docker-compose.yml
8. **Token-Rotation**: Erneuern Sie Tokens jährlich

---

## ⚙️ Repository-Struktur

```
Containers/
├── .github/
│   ├── workflows/
│   │   ├── renovate.yml              # GitHub Actions
│   │   └── validate-compose.yml      # Validierung
│   ├── CODEOWNERS
│   └── pull_request_template.md
├── backrest/
│   └── docker-compose.yml
├── immich/
│   └── docker-compose.yml
├── keycloak/
│   └── docker-compose.yml
├── kopia/
│   └── docker-compose.yml
├── renovate.json                     # Haupt-Konfiguration
├── .renovaterc.json5                 # Alternative Config
├── validate-compose.sh               # Validierung
├── .env.example                      # Beispiel-Env-Vars
├── RENOVATE.md                       # Diese Datei
└── README.md                         # Repository-Übersicht
```

---

## ✅ Checkliste

**Vor der Installation:**

- [ ] Dokumentation lesen
- [ ] `.env.example` nach `.env` kopieren
- [ ] Default-Passwörter ändern

**Installation:**

- [ ] Token erstellen (falls GitHub Actions verwendet wird)
- [ ] Als Secret hinzufügen
- [ ] Konfiguration committen
- [ ] App installieren (GitHub App) oder Workflow testen
- [ ] Onboarding-PR mergen

**Nach der Installation:**

- [ ] Dependency Dashboard prüfen
- [ ] Ersten Update-PR ansehen
- [ ] Optional: `renovate.json` anpassen
- [ ] CODEOWNERS anpassen

---

**Status**: ✅ Einsatzbereit  
**Plattform**: GitHub  
**Services**: 4 (Backrest, Immich, Keycloak, Kopia)  
**Validierung**: ✅ Alle docker-compose.yml korrekt

