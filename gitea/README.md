# Gitea — privates Git und OpenTofu-State

Zwei Aufgaben, ein Dienst:

1. **Privates Repo für die `terraform.tfvars`** 
2. **State-Registry** als `backend "http"` mit echtem Locking.

## Ersteinrichtung

Der Web-Installer ist mit `INSTALL_LOCK` von Anfang an tot. Das erste Konto entsteht deshalb
auf der Kommandozeile:

```bash
docker exec -u 99:100 gitea gitea admin user create --username nico --email nico.steinmueller@gmx.net --admin --random-password
```

Danach anmelden, unter *Einstellungen → Anwendungen* einen Token anlegen und
ihm die Berechtigungen **`write:package`** (State-Registry) und
**`write:repository`** (tfvars) geben.

## Konfiguration der Arbeitsstation

Was `tofu` und `git` brauchen, liegt unter `~/.config/homelab`:

| Was | Wo | Warum dort |
|---|---|-|
| Gitea-Token samt Benutzername | `~/.config/homelab/gitea.env` | |
| State-Passphrase | `~/.config/homelab/tofu.env` | |

**Klartext im Dateisystem heißt:** Jeder Prozess, der als du läuft, kann die
Werte lesen — sie liegen im Klartext auf der Platte, geschützt allein durch die
Dateirechte (`700` auf das Verzeichnis, `600` auf die Dateien). Ein separat
entsperrter Schlüsselbund wäre strenger, kostet aber bei jeder Sitzung eine
Passwortabfrage. Gewinn: Der State verlässt das Gerät nur verschlüsselt, im
Gitea-Backup steckt keine Cluster-PKI mehr, und nichts davon steht in der
Umgebung jeder Shell. Gegen jemanden, der bereits als du Code auf dieser
Maschine ausführt, schützt keine der beiden Varianten wirklich.

Bewusst außerhalb der Repos: Eine Datei neben dem Modul wäre genau die, die
beim nächsten `git add .` im falschen Verzeichnis mitgeht.

Geheimnisse holt [`tools/tf`](../tools/tf) beim Aufruf und gibt sie nur an den
einen tofu-Prozess weiter — über die Umgebung, nicht als Argument: Argumente
stehen in der Prozessliste, die Umgebung eines fremden Prozesses nicht.

### Geheimnisse auf der Arbeitsstation

```bash
mkdir -p ~/.config/homelab && chmod 700 ~/.config/homelab
umask 077

cat > ~/.config/homelab/gitea.env <<'EOF'
HOMELAB_GITEA_USER='nico'
HOMELAB_GITEA_TOKEN='<token>'
EOF

cat > ~/.config/homelab/tofu.env <<'EOF'
HOMELAB_TOFU_STATE='<passphrase>'
EOF
```

Die Werte stehen in **einfachen** Anführungszeichen: Die Dateien werden von den
Wrappern gesourct, ohne sie machte ein `$` oder ein Leerzeichen im Token aus
dem Wert etwas anderes. Enthält ein Wert selbst ein `'`, wird es als
`'\''` geschrieben.

Der age-Schlüssel für SOPS liegt **nicht** hier, sondern unter
`~/.config/sops/age/keys.txt` — dort, wo sops von allein sucht. Angelegt wird er
in `homelab-secrets/README.md`.

Gegenprobe, ohne die Werte auf den Schirm zu holen — die Länge verrät einen
verschluckten Einfügevorgang sofort:

```bash
ls -l ~/.config/homelab                    # 600, Besitzer du
( . ~/.config/homelab/gitea.env; echo ${#HOMELAB_GITEA_TOKEN} )  # 40 (Gitea-Token)
( . ~/.config/homelab/tofu.env;  echo ${#HOMELAB_TOFU_STATE} )   # so lang wie die Passphrase
```

### Credential-Helper für das Werte-Repo

Einmal im Werte-Repo setzen (lokal, nicht global — der Helper gilt nur für
dieses Remote). Er zeigt auf denselben Helper, den auch `tf` benutzt, damit es
beim Tokenwechsel keine zweite Stelle gibt:

```bash
git -C "$HOMELAB_VALUES" config credential.helper \
  '!/home/nico/Repos/Homelab/Container/tools/gitea-credential'
```

### Wrapper für tofu
Wer den Wrapper öfter braucht, legt ihn auf den `PATH` und ruft ihn danach aus
jedem Modul einfach als `tf` auf:

```bash
ln -s ~/Repos/Homelab/Container/tools/tf ~/.local/bin/tf
```

## State-Verschlüsselung

Konfiguriert wird das nicht im Modul, sondern über `TF_ENCRYPTION` aus
[`tools/tf`](../tools/tf): Im `encryption`-Block sind weder Variablen noch
Funktionen erlaubt, eine Passphrase im Code stünde also im Klartext auf GitHub.
Verfahren ist AES-GCM, der Schlüssel kommt per PBKDF2 aus der Passphrase.

In der Registry steht danach nur noch:

```json
{"encrypted_data":"…","key_provider":{"pbkdf2":{"main":{"salt":"…"}}}}
```

### Passphrase wechseln

neuen `key_provider` dazu, den alten als `fallback`, einmal `apply -refresh-only` 
je Modul, dann den alten entfernen.

## State anbinden

Im `backend`-Block jedes Moduls `local` durch `http` ersetzen. Der Name am
Ende der Adresse ist der Modulpfad, flach geschrieben (`vm/talos` →
`vm-talos`):

```hcl
terraform {
  backend "http" {
    address        = "https://git.local.nico-steinmueller.de/api/packages/nico/terraform/state/vm-talos"
    lock_address   = "https://git.local.nico-steinmueller.de/api/packages/nico/terraform/state/vm-talos/lock"
    unlock_address = "https://git.local.nico-steinmueller.de/api/packages/nico/terraform/state/vm-talos/lock"
    lock_method    = "POST"
    unlock_method  = "DELETE"
  }
}
```

## Sicherung

```bash
docker compose -f compose.yml -f compose.prod.yml stop gitea
# → /mnt/user/appdata/gitea sichern (kopia, Restic, was auch immer)
docker compose -f compose.yml -f compose.prod.yml start gitea
```

Im laufenden Betrieb geht auch `docker exec -u 99:100 gitea gitea dump -t /tmp`
