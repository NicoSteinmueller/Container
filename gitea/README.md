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

## Die Datei `~/.config/tofu/gitea.env`

| Variable | Liest | Wofür |
|---|---|---|
| `TF_HTTP_USERNAME`, `TF_HTTP_PASSWORD` | `tofu`, `git` | Auth gegen die State-Registry. `tofu` wertet die `TF_HTTP_*` für den `http`-Backend von allein aus — deshalb stehen im `backend`-Block keine Zugangsdaten. Derselbe Token zieht über einen Credential-Helper auch das Werte-Repo (siehe unten). |
| `HOMELAB_VALUES` | [`tools/tf`](../tools/tf) | Wurzel des Werte-Repos. Der Wrapper hängt den Modulpfad an und landet bei der `terraform.tfvars`. Fehlt die Variable, nimmt er `~/Repos/homelab-values`. |

Anlegen:

```bash
mkdir -p ~/.config/tofu && chmod 700 ~/.config/tofu
umask 077 && cat > ~/.config/tofu/gitea.env <<'EOF'
export TF_HTTP_USERNAME="nico"
export TF_HTTP_PASSWORD="<Token mit write:package>"
export HOMELAB_VALUES="$HOME/Repos/Homelab/homelab-values"
EOF
chmod 600 ~/.config/tofu/gitea.env
```

Geladen wird sie nicht von `tofu`, sondern von der Shell — eine Zeile in
`~/.bashrc` genügt:

```bash
echo '[ -f ~/.config/tofu/gitea.env ] && . ~/.config/tofu/gitea.env' >> ~/.bashrc
```

Das `[ -f ... ] &&` davor, damit eine Shell auf einem Rechner ohne die Datei
nicht bei jedem Start eine Fehlermeldung wirft.

Zum Prüfen, ohne den Token auf den Schirm zu holen:

```bash
env | grep -c 'TF_HTTP_\|HOMELAB_VALUES'   # erwartet: 3
```

Wer den Wrapper öfter braucht, legt ihn auf den `PATH` und ruft ihn danach aus
jedem Modul einfach als `tf` auf:

```bash
ln -s ~/Repos/Homelab/Container/tools/tf ~/.local/bin/tf
```

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
