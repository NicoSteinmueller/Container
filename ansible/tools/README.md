# Tools

Ein allgemeines Playbook, das den Soll-Zustand von Entwickler-Tools auf allen
Hosts herstellt. Installieren, Deinstallieren und Aktualisieren ist derselbe
Lauf - was passiert, steht ausschliesslich in
[group_vars/all.yml](group_vars/all.yml).

Fuer jedes installierte Tool werden automatische Updates ueber
`unattended-upgrades` eingerichtet. Das ist keine Option, sondern erzwungen:
registriert eine Rolle keinen Update-Kanal, bricht das Playbook mit einem Fehler
ab, statt ein Tool ohne Update-Pfad zurueckzulassen.

## Zwei Sorten Tool

Der Unterschied liegt nicht in der Bedienung - beide stehen gleichberechtigt in
`managed_tools` - sondern darin, woher die Updates kommen:

| | **Eigenes Repository** | **Distributionspaket** |
|---|---|---|
| Verwaltet | `opentofu` | derzeit keins - `distro_package` steht bereit |
| Rolle | eine je Tool, richtet Keyrings und apt-Repo ein | duenner Wrapper auf die gemeinsame Rolle `distro_package` |
| Update-Kanal | wird von der Rolle nach `52-ansible-managed-tools` geschrieben | steht schon in `50unattended-upgrades` |
| Buchfuehrung | `tool_update_coverage` | `tool_update_sources` |
| Rolle des Playbooks | **setzen** und danach pruefen, dass apt das Muster kennt | nur **pruefen**, dass der Kanal erlaubt ist |

Die Trennung ist Absicht. Ein Distributionspaket wird bereits ueber
`${distro_id}:${distro_codename}` und `-security` aktualisiert; diese Origins
ein zweites Mal zu deklarieren waere doppelte Wahrheit - und ein Tippfehler
dabei, etwa ein zusaetzliches `-updates`, schaltete unbemerkt automatische
Nicht-Security-Updates fuer das ganze System ein. Stattdessen prueft
`auto_updates` bei jedem Lauf nach, dass die Kanaele wirklich erlaubt sind, und
bricht ab, wenn jemand sie aus `50unattended-upgrades` entfernt hat.

Reine Binary-Downloads bleiben aussen vor - fuer sie gibt es ueberhaupt keinen
Kanal, den `unattended-upgrades` bedienen koennte.

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

**Aus den Distributionsquellen** (`apt-cache policy <paket>` zeigt das Archiv
der Distribution) — zwei Schritte:

1. `roles/<tool>/tasks/main.yml` anlegen, das `distro_package` einbindet:

   ```yaml
   - name: Manage <tool> as a distribution package
     ansible.builtin.include_role:
       name: distro_package
     vars:
       distro_package_state: "{{ tool_state }}"
       distro_package_name: <paket>
       distro_package_tool: <tool>
   ```

   `distro_package_state` muss ausdruecklich weitergereicht werden. Sich darauf
   zu verlassen, dass `tool_state` durch zwei verschachtelte `include_role`
   hindurch sichtbar bleibt, waere die eine Nachlaessigkeit, die nicht auffiele:
   Die Rolle fiele still auf `present` zurueck und ignorierte jedes `absent`.
   Ein Assert in `distro_package` faengt das ab.

2. Das Tool in `group_vars/all.yml` unter `managed_tools` eintragen.

**Mit eigenem apt-Repository** — drei Schritte, `roles/opentofu` ist die
Vorlage:

1. `roles/<tool>/` anlegen mit `tasks/main.yml` (Weiche auf `tool_state`),
   `tasks/install.yml`, `tasks/uninstall.yml` und `defaults/main.yml`.
2. In `install.yml` das apt-Repository einrichten und am Ende
   `tool_update_coverage` um die Origins des Repos ergaenzen. Die passenden
   Werte liefert `apt-cache policy` in der Zeile `release o=...,l=...`.
3. Das Tool in `group_vars/all.yml` unter `managed_tools` eintragen.

Reine Binary-Downloads passen weiterhin in kein Schema, weil es fuer sie keinen
Update-Kanal gibt, den `unattended-upgrades` bedienen koennte. Der Assert in
`tools.yml` macht darauf aufmerksam, statt sie stillschweigend ungepatcht zu
lassen. Solche Tools brauchen einen eigenen Mechanismus - der
Assert in `tools.yml` macht darauf aufmerksam, statt sie stillschweigend
ungepatcht zu lassen.
