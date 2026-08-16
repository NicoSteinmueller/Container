# Gitea — privates Git und OpenTofu-State

Zwei Aufgaben, ein Dienst:

1. **Privates Repo für die `terraform.tfvars`** 
2. **State-Registry** als `backend "http"` mit echtem Locking.

## Ersteinrichtung

Der Web-Installer ist mit `INSTALL_LOCK` von Anfang an tot — es gibt kein
Zeitfenster, in dem `/install` offen steht. Das erste Konto entsteht deshalb
auf der Kommandozeile:

```bash
docker exec -u 99:100 gitea gitea admin user create --username nico --email nico.steinmueller@gmx.net --admin --random-password
```

Danach anmelden, unter *Einstellungen → Anwendungen* einen Token anlegen und
ihm die Berechtigungen **`write:package`** (State-Registry) und
**`write:repository`** (tfvars) geben. Ein Token mit allen Rechten braucht es
nicht.

Das Repo für die Werte anlegen — `FORCE_PRIVATE` sorgt dafür, dass es privat
ist, auch wenn man beim Anlegen daneben klickt:

```bash
git clone https://git.nico-steinmueller.de/nico/homelab-values.git
```

## OpenTofu anbinden

Im `backend`-Block jedes Moduls `local` durch `http` ersetzen. Der Name am
Ende der Adresse ist derselbe flache Schlüssel, den `tools/tf` heute schon
bildet (`vm/talos` → `vm-talos`):

```hcl
terraform {
  backend "http" {
    address        = "https://git.nico-steinmueller.de/api/packages/nico/terraform/state/vm-talos"
    lock_address   = "https://git.nico-steinmueller.de/api/packages/nico/terraform/state/vm-talos/lock"
    unlock_address = "https://git.nico-steinmueller.de/api/packages/nico/terraform/state/vm-talos/lock"
    lock_method    = "POST"
    unlock_method  = "DELETE"
  }
}
```

Zugangsdaten gehören nicht in den Block — der `http`-Backend liest sie aus der
Umgebung:

```bash
export TF_HTTP_USERNAME=nico
export TF_HTTP_PASSWORD=<token mit write:package>
```

Ein `export` überlebt die Shell nicht, in der es getippt wurde. Damit jedes
neue Fenster die Werte hat, in eine eigene Datei legen statt in `~/.bashrc` —
die ist `644` und damit für jedes Konto auf dem Rechner lesbar:

```bash
mkdir -p ~/.config/tofu && chmod 700 ~/.config/tofu
umask 077 && cat > ~/.config/tofu/gitea.env <<'EOF'
export TF_HTTP_USERNAME="nico"
export TF_HTTP_PASSWORD="<token mit write:package>"
EOF
chmod 600 ~/.config/tofu/gitea.env

echo '[ -f ~/.config/tofu/gitea.env ] && . ~/.config/tofu/gitea.env' >> ~/.bashrc
```

Der Token liegt damit im Klartext auf der Platte, geschützt allein durch die
Dateirechte. Wem das zu wenig ist: als `gpg`-verschlüsselte Datei ablegen und
in einer `tofu()`-Wrapper-Funktion erst beim Aufruf entschlüsseln.

`~/.bashrc` gilt nur für interaktive Shells — Cron, systemd-Units und
`ssh host 'tofu ...'` müssen die Datei selbst sourcen.

## Sicherung

Hier liegt das, womit der Cluster wiederhergestellt wird — die Sicherung ist
kein Nebenaspekt, sondern der Grund für mehrere Entscheidungen weiter unten.
Repos, SQLite-Datenbank und Package-Registry liegen alle unter einem Pfad:

```bash
docker compose -f compose.yml -f compose.prod.yml stop gitea
# → /mnt/user/appdata/gitea sichern (kopia, Restic, was auch immer)
docker compose -f compose.yml -f compose.prod.yml start gitea
```

Im laufenden Betrieb geht auch `docker exec -u 99:100 gitea gitea dump -t /tmp`
— das erzeugt ein konsistentes Archiv, ohne den Dienst anzuhalten.
