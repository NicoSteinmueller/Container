# Tools

Ein allgemeines Playbook, das den Soll-Zustand von Entwickler-Tools auf allen
Hosts herstellt. Installieren, Deinstallieren und Aktualisieren ist derselbe
Lauf - was passiert, steht ausschliesslich in
[group_vars/all.yml](group_vars/all.yml).

Fuer jedes installierte Tool werden automatische Updates ueber
`unattended-upgrades` eingerichtet. Das ist keine Option, sondern erzwungen:
registriert eine Rolle keinen Update-Kanal, bricht das Playbook mit einem Fehler
ab, statt ein Tool ohne Update-Pfad zurueckzulassen.

## Drei Sorten Tool

Der Unterschied liegt nicht in der Bedienung - beide stehen gleichberechtigt in
`managed_tools` - sondern darin, woher die Updates kommen:

| | **Eigenes Repository** | **Distributionspaket** | **Release-Binary** |
|---|---|---|---|
| Verwaltet | `opentofu` | `age` | `sops` |
| Rolle | eine je Tool, richtet Keyrings und apt-Repo ein | duenner Wrapper auf die gemeinsame Rolle `distro_package` | duenner Wrapper auf die gemeinsame Rolle `github_binary` |
| Update-Kanal | wird von der Rolle nach `52-ansible-managed-tools` geschrieben | steht schon in `50unattended-upgrades` | der Versions-Pin in der Rolle, angehoben von Renovate |
| Buchfuehrung | `tool_update_coverage` | `tool_update_sources` | `tool_update_pinned` |
| Rolle des Playbooks | **setzen** und danach pruefen, dass apt das Muster kennt | nur **pruefen**, dass der Kanal erlaubt ist | **einspielen**, was der Pin sagt |
| Eingespielt durch | `apt-daily-upgrade.timer` | `apt-daily-upgrade.timer` | den naechsten Playbook-Lauf |

Die Trennung ist Absicht. Ein Distributionspaket wird bereits ueber
`${distro_id}:${distro_codename}` und `-security` aktualisiert; diese Origins
ein zweites Mal zu deklarieren waere doppelte Wahrheit - und ein Tippfehler
dabei, etwa ein zusaetzliches `-updates`, schaltete unbemerkt automatische
Nicht-Security-Updates fuer das ganze System ein. Stattdessen prueft
`auto_updates` bei jedem Lauf nach, dass die Kanaele wirklich erlaubt sind, und
bricht ab, wenn jemand sie aus `50unattended-upgrades` entfernt hat.

Die dritte Spalte ist die juengste und die schwaechste, und das soll sie auch
bleiben. `unattended-upgrades` kann diese Tools nicht bedienen - es gibt kein
Repository, dessen Origin man eintragen koennte. Statt sie deshalb ganz
auszuschliessen (was frueher hier stand) tragen sie ihren Pin in
`tool_update_pinned` ein: Renovate hebt die Version per Pull Request an
(`renovate.json5`, Manager auf `ansible/tools/roles/*/defaults/main.yml`), der
naechste Playbook-Lauf zieht sie nach.

Der Unterschied zu den ersten beiden Spalten ist messbar und wird nicht
weggeredet: Zwischen Release und eingespieltem Update liegen ein Merge und ein
Playbook-Lauf, nicht ein Timer. Es ist aber ein Kanal mit einem
Verantwortlichen - und damit etwas anderes als eine von Hand kopierte Binary,
die niemand mehr anfasst. Wo ein Tool auch als Paket zu haben ist, gehoert es
weiterhin in Spalte zwei.

## Soll-Zustand definieren

```yaml
# group_vars/all.yml
managed_tools:
  opentofu: present          # installieren und aktuell halten
  age: present
  sops: present
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

| Tool              | Paket             | Binary                | Quelle                                  |
| ----------------- | ----------------- | --------------------- | --------------------------------------- |
| `opentofu`        | `tofu`            | `tofu`                | `packages.opentofu.org` (zwei GPG-Keys) |
| `age`             | `age`             | `age`, `age-keygen`   | Distributionsquellen (universe)         |
| `sops`            | -                 | `sops`                | GitHub Releases `getsops/sops`, gepinnt |

`age` und `sops` gehoeren zusammen: `age-keygen` erzeugt die Schluessel,
`sops` ver- und entschluesselt damit die Kubernetes-Secrets in
`homelab-secrets`. Weil dieser Rechner damit die Geheimnisse des Clusters
aufschliesst, wird die sops-Binary nie ohne Pruefsummenabgleich installiert -
`github_binary` bricht ab, wenn das Release keine passende Zeile in seiner
`checksums.txt` enthaelt. Hintergrund in
[k8s/flux/README.md](../../k8s/flux/README.md).

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

**Als Release-Binary von GitHub** - wenn es das Tool weder als Paket noch aus
einem apt-Repository des Herstellers gibt (`apt-cache policy <paket>` bleibt
leer). `roles/sops` ist die Vorlage, drei Schritte:

1. `roles/<tool>/defaults/main.yml` mit der gepinnten Version anlegen. Der
   Kommentar darueber ist nicht optional - er sagt Renovate, welches Repo
   gemeint ist:

   ```yaml
   # renovate: datasource=github-releases depName=<owner>/<repo>
   <tool>_version: v1.2.3
   ```

2. `roles/<tool>/tasks/main.yml` anlegen, das `github_binary` einbindet und
   Repository, Asset-Namen und die Datei mit den Pruefsummen setzt. Ohne
   `github_binary_checksums_asset` bricht die Rolle ab - eine Binary aus dem
   Netz ohne Pruefsumme wird hier nicht installiert.

3. Das Tool in `group_vars/all.yml` unter `managed_tools` eintragen.

Am `renovate.json5` ist nichts nachzutragen: Der Manager greift generisch auf
`ansible/tools/roles/*/defaults/main.yml` und liest Datasource und Repo aus dem
Kommentar.
