# SFTPGo Backup-Strategie

## 📦 Was muss gesichert werden?

### ✅ Mit SFTPGo Native Backup
- **Benutzer** (Accounts, Passwörter, Public Keys)
- **Gruppen** (Benutzergruppen, Berechtigungen)
- **Admins** (Administrator-Konten)
- **API Keys** (API-Zugänge)
- **Shares** (Öffentliche Freigabe-Links)
- **Actions & Rules** (Event-Automatisierungen)
- **Rollen** (Benutzer-/Admin-Rollen)
- **IP-Listen** (Whitelist/Blacklist)

### ✅ Mit Kopia/Backrest
- **`./data/`** - Alle Benutzerdateien (Uploads)
- **`./config/`** - SSH-Schlüssel (id_ecdsa, id_ed25519, id_rsa)
- **`./backups/`** - SFTPGo Native Backups (JSON)

### ✅ Optional: PostgreSQL Dump
- Datenbank als Fallback (bei Major-Upgrades nützlich)

---

## 🔄 Empfohlener Backup-Prozess

### 1️⃣ **Tägliches SFTPGo Native Backup**

**Via WebAdmin UI:**
1. Öffne `http://localhost:8081` (WebAdmin)
2. Login als Admin
3. Gehe zu: `Maintenance` → `Backup`
4. Klicke auf `Create Backup`
5. Backup wird in `./backups/` gespeichert

**Via REST API (automatisiert):**
```powershell
# Backup erstellen
$headers = @{
    "X-SFTPGO-API-KEY" = "your-api-key"
}
Invoke-RestMethod -Uri "http://localhost:8081/api/v2/dumpdata" `
    -Method GET -Headers $headers -OutFile ".\backups\backup_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
```

**Frequenz:** Täglich um 02:00 Uhr

---

### 2️⃣ **Kopia/Backrest Backup**

**Was sichern:**
```
C:\Entwicklung\Container\sftpgo\data\      → Benutzerdaten
C:\Entwicklung\Container\sftpgo\config\    → SSH-Schlüssel
C:\Entwicklung\Container\sftpgo\backups\   → Native Backups
```

**Frequenz:** Täglich um 03:00 Uhr (nach Native Backup)

**Retention Policy:**
- Täglich: 7 Tage
- Wöchentlich: 4 Wochen
- Monatlich: 12 Monate

---

### 3️⃣ **Cleanup alter lokaler Backups**

**Nach erfolgreicher Kopia-Sicherung:**
```powershell
# Lokale Backups älter als 14 Tage löschen
Get-ChildItem -Path "C:\Entwicklung\Container\sftpgo\backups" -Filter "backup_*.json" |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-14) } |
    Remove-Item -Force
```

**Frequenz:** Täglich um 04:00 Uhr (nach Kopia-Backup)

---

### 4️⃣ **Optional: PostgreSQL Dump**

**Wöchentliches Datenbank-Backup:**
```powershell
docker exec sftpgo_postgres pg_dump -U sftpgo sftpgo > ".\backups\postgres_$(Get-Date -Format 'yyyyMMdd').sql"
```

**Frequenz:** Wöchentlich (Sonntag 02:00 Uhr)

---

## 🔧 Automatisierung (Windows Task Scheduler)

### Script: `backup-sftpgo.ps1`
```powershell
# 1. SFTPGo Native Backup via API
$apiKey = "your-api-key-here"
$headers = @{ "X-SFTPGO-API-KEY" = $apiKey }
$backupFile = "C:\Entwicklung\Container\sftpgo\backups\backup_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"

try {
    Invoke-RestMethod -Uri "http://localhost:8081/api/v2/dumpdata" `
        -Method GET -Headers $headers -OutFile $backupFile
    Write-Host "✅ SFTPGo Backup erstellt: $backupFile"
} catch {
    Write-Error "❌ SFTPGo Backup fehlgeschlagen: $_"
}

# 2. Warte auf Kopia/Backrest (extern getriggert)
Start-Sleep -Seconds 300

# 3. Cleanup alter Backups (älter als 14 Tage)
Get-ChildItem -Path "C:\Entwicklung\Container\sftpgo\backups" -Filter "backup_*.json" |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-14) } |
    Remove-Item -Force

Write-Host "✅ Alte Backups gelöscht"
```

**Task Scheduler Einstellung:**
- Trigger: Täglich um 02:00 Uhr
- Aktion: `powershell.exe -File "C:\Entwicklung\Container\sftpgo\backup-sftpgo.ps1"`

---

## 🔄 Wiederherstellung

### SFTPGo Konfiguration wiederherstellen

**Via WebAdmin UI:**
1. Öffne `http://localhost:8081`
2. Gehe zu: `Maintenance` → `Restore`
3. Wähle Backup-Datei (`backup_*.json`)
4. Klicke auf `Restore`

**Via REST API:**
```powershell
$headers = @{ "X-SFTPGO-API-KEY" = "your-api-key" }
$backupContent = Get-Content ".\backups\backup_20260131.json" -Raw

Invoke-RestMethod -Uri "http://localhost:8081/api/v2/loaddata" `
    -Method POST -Headers $headers `
    -ContentType "application/json" -Body $backupContent
```

### Benutzerdaten wiederherstellen
```powershell
# Via Kopia/Backrest aus dem gewünschten Snapshot
kopia snapshot restore <snapshot-id> C:\Entwicklung\Container\sftpgo\data\
```

---

## ⚠️ Wichtige Hinweise

1. **SFTPGo löscht KEINE alten Backups automatisch** - manuelles Cleanup erforderlich!
2. **PostgreSQL Volume** (`postgres`) wird NICHT mit bind mounts gesichert - Docker Volume Backup nötig oder pg_dump verwenden
3. **SSH-Schlüssel** in `./config/` sind kritisch - ohne diese funktioniert SFTP nicht!
4. **Native Backups sind versionssicher** - funktionieren auch bei SFTPGo-Updates
5. **API-Key erstellen:** WebAdmin → `Admins` → API Keys → `Add`

---

## 📊 Backup-Übersicht

| Was | Methode | Frequenz | Retention |
|-----|---------|----------|-----------|
| Metadaten (Users, Groups, etc.) | SFTPGo Native | Täglich 02:00 | 14 Tage lokal |
| Benutzerdateien (`./data/`) | Kopia/Backrest | Täglich 03:00 | 7d/4w/12m |
| SSH-Keys (`./config/`) | Kopia/Backrest | Täglich 03:00 | 7d/4w/12m |
| Native Backups (`./backups/`) | Kopia/Backrest | Täglich 03:00 | 7d/4w/12m |
| PostgreSQL | pg_dump (optional) | Wöchentlich | 4 Wochen |

---

## ✅ Backup-Checkliste

- [ ] SFTPGo Native Backup via API/WebAdmin konfiguriert
- [ ] Kopia/Backrest für `./data/`, `./config/`, `./backups/` eingerichtet
- [ ] Cleanup-Script für alte lokale Backups erstellt
- [ ] Windows Task Scheduler für Automatisierung eingerichtet
- [ ] Wiederherstellung getestet (Disaster Recovery Test!)
- [ ] API-Key für automatisierte Backups erstellt
- [ ] Monitoring/Alerts bei Backup-Fehlern eingerichtet
