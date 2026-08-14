# Tools

Ein allgemeines Playbook, das den Soll-Zustand von Entwickler-Tools auf allen
Hosts herstellt. Installieren, Deinstallieren und Aktualisieren ist derselbe
Lauf - was passiert, steht ausschliesslich in
[group_vars/all.yml](group_vars/all.yml).

Fuer jedes installierte Tool werden automatische Updates ueber
`unattended-upgrades` eingerichtet. Das ist keine Option, sondern erzwungen:
registriert eine Rolle keine apt-Origins, bricht das Playbook mit einem Fehler
ab, statt ein Tool ohne Update-Pfad zurueckzulassen.

## Soll-Zustand definieren

```yaml
# group_vars/all.yml
managed_tools:
  opentofu: present    # installieren und aktuell halten
```

`absent` entfernt Paket, Repository und Signing-Keys - und nimmt das Tool
gleichzeitig aus der unattended-upgrades-Konfiguration heraus, weil diese bei
jedem Lauf komplett neu aufgebaut wird.

Host-spezifische Abweichungen gehoeren in `host_vars/<host>.yml`.

## Hosts

Dieses Verzeichnis hat ein eigenes [inventory.ini](inventory.ini), unabhaengig
vom Inventar der Einzel-Playbooks eine Ebene hoeher. Weitere Systeme dort unter
`[workstations]` ergaenzen - sie bekommen damit automatisch dieselbe
Basissoftware aus `group_vars/all.yml`.

## Ausfuehren

```bash
cd ansible/tools

# Nur pruefen, was sich aendern wuerde - nuetzlich zum Drift-Check
ansible-playbook -i inventory.ini tools.yml --check --diff

# Soll-Zustand herstellen
ansible-playbook -i inventory.ini tools.yml

# Einzelnes Tool ad hoc umschalten, ohne group_vars zu aendern
ansible-playbook -i inventory.ini tools.yml -e '{"managed_tools":{"opentofu":"absent"}}'
```

Die Tasks laufen mit `become`, brauchen also root - entweder per `--ask-become-pass`
oder indem das Playbook selbst mit `sudo` gestartet wird.

### Was `--check` nicht zeigen kann

Fehlt ein Repository auf dem Host noch, kann apt im Probelauf auch das Paket
daraus nicht sehen - das Repository wurde ja nur simuliert. Das Playbook
ueberspringt die Paket-Installation in diesem Fall mit einem Hinweis, statt
abzubrechen. Auf Hosts, die das Repository schon haben, meldet `--check` ganz
normal, ob ein Update ansteht.

Aus demselben Grund laufen die Verifikationen (Origin-/Label-Abgleich,
Rueckgelesene unattended-upgrades-Muster) nur im echten Lauf.

## Verfuegbare Tools

| Tool       | Paket  | Quelle                                    |
| ---------- | ------ | ----------------------------------------- |
| `opentofu` | `tofu` | `packages.opentofu.org` (zwei GPG-Keys)   |

## Wie die automatischen Updates funktionieren

`unattended-upgrades` aktualisiert nur Repositories, deren Origin es kennt. Die
Distribution bringt ihre eigenen Security-Origins in
`/etc/apt/apt.conf.d/50unattended-upgrades` mit; Repos von Drittanbietern muessen
ergaenzt werden, sonst laufen deren Pakete stillschweigend veraltet weiter.

Der Ablauf:

1. Jede Tool-Rolle traegt beim Installieren ihre Origins in die Variable
   `tool_update_coverage` ein (siehe `opentofu_unattended_origins` in
   [roles/opentofu/defaults/main.yml](roles/opentofu/defaults/main.yml)).
2. `tools.yml` prueft, dass jedes auf `present` gesetzte Tool das auch getan hat.
3. Die Rolle `auto_updates` schreibt daraus
   `/etc/apt/apt.conf.d/52-ansible-managed-tools`. apt haengt Listenwerte ueber
   mehrere Dateien hinweg aneinander, die Security-Origins der Distribution
   bleiben also erhalten.
4. `apt-daily.timer` und `apt-daily-upgrade.timer` werden aktiviert - ohne sie
   waere die Konfiguration wirkungslos.
5. Zum Schluss liest das Playbook mit `apt-config dump` zurueck, welche Muster
   apt tatsaechlich geparst hat, und bricht bei einer Abweichung ab.

Stellschrauben (Reboot-Verhalten, Paket-Blacklist, zusaetzliche Origins) stehen
in [roles/auto_updates/defaults/main.yml](roles/auto_updates/defaults/main.yml).
Ein automatischer Neustart ist bewusst deaktiviert.

Pruefen, was zuletzt automatisch aktualisiert wurde:

```bash
systemctl list-timers 'apt-daily*'
cat /var/log/unattended-upgrades/unattended-upgrades.log
unattended-upgrade --dry-run --debug   # zeigt, welche Origins beruecksichtigt werden
```

## Ein weiteres Tool ergaenzen

1. `roles/<tool>/` anlegen mit `tasks/main.yml` (Weiche auf `tool_state`),
   `tasks/install.yml`, `tasks/uninstall.yml` und `defaults/main.yml`.
2. In `install.yml` das apt-Repository einrichten und am Ende
   `tool_update_coverage` um die Origins des Repos ergaenzen. Die passenden
   Werte liefert `apt-cache policy` in der Zeile `release o=...,l=...`.
3. Das Tool in `group_vars/all.yml` unter `managed_tools` eintragen.

Tools ohne apt-Repository (reine Binary-Downloads) passen nicht in dieses
Schema, weil es fuer sie keinen Update-Kanal gibt, den `unattended-upgrades`
bedienen koennte. Solche Tools brauchen einen eigenen Mechanismus - der
Assert in `tools.yml` macht darauf aufmerksam, statt sie stillschweigend
ungepatcht zu lassen.
