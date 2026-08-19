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

Alles Geheime liegt im Schlüsselbund, sonst nirgends:

| Was | Wo | Warum dort |
|---|---|-|
| Gitea-Token samt Benutzername | Schlüsselbund | |
| State-Passphrase | Schlüsselbund | |

**Beides im Schlüsselbund heißt:** Jeder Prozess, der als du läuft, kann beide Werte
lesen. Ein eigener, separat entsperrter Schlüsselbund wäre strenger, kostet aber bei 
jeder Sitzung eine Passwortabfrage. Gewinn: Der State verlässt das Gerät nur 
verschlüsselt, im Gitea-Backup steckt keine Cluster-PKI mehr, und nichts davon steht 
in der Umgebung jeder Shell. Gegen jemanden, der bereits als du Code auf dieser
Maschine ausführt, schützt keine der beiden Varianten wirklich.

Geheimnisse holt [`tools/tf`](../tools/tf) beim Aufruf und gibt sie nur an den einen
tofu-Prozess weiter.

### Geheimnisse im Schlüsselbund

```bash
sudo apt install libsecret-tools
```

*Über richtiges Terminal ausführen (nicht IntelliJ)*
```bash
secret-tool store --label='Gitea Token' homelab gitea-token username nico
secret-tool store --label='OpenTofu State' homelab tofu-state
```

Der Gitea-Eintrag trägt zwei Angaben: der **Token ist das Geheimnis**, der
**Benutzername ein Attribut** daneben. `secret-tool lookup homelab gitea-token` 
findet den Eintrag weiterhin; die angegebenen Attribute müssen nur vorhandenen sein.

Gegenprobe, ohne die Werte auf den Schirm zu holen — die Länge verrät einen
verschluckten Einfügevorgang sofort:

```bash
secret-tool search --all homelab gitea-token   # Pfad .../collection/login/<n>, dazu attribute.username
secret-tool lookup homelab gitea-token | wc -c # 40 (Gitea-Token)
secret-tool lookup homelab tofu-state  | wc -c # so lang wie die Passphrase
```


### Credential-Helper für das Werte-Repo

Einmal im Werte-Repo setzen (lokal, nicht global — der Helper gilt nur für
dieses Remote):

```bash
git -C "$HOMELAB_VALUES" config credential.helper \
  '!f() { test "$1" = get || return 0; secret-tool search --all homelab gitea-token 2>&1 >/dev/null | sed -n "s/^attribute.username = /username=/p" | head -1; echo "password=$(secret-tool lookup homelab gitea-token)"; }; f'
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
