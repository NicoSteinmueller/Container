# Flux (GitOps)

Push auf `var.git_branch` rollt aus, ohne `kubectl apply` von Hand - dieselbe
Automatik, die Portainer für die Compose-Stacks liefert. Das Modul installiert
Flux Operator und eine `FluxInstance`, die dieses Repo beobachtet.

| | |
|---|---|
| Quelle | `k8s/flux/clusters/talos-cp1` aus diesem Repo (`sync_path`) |
| Zugang | Flux-Status-Seite, NodePort `30081`, ohne Login |
| Secrets | `homelab-secrets` (Gitea), SOPS-verschlüsselt |
| Bootstrap | drei Secrets, leer angelegt, per `tools/sops-bootstrap` befüllt |

## Anwenden

State **und** Werte liegen in Gitea

```bash
cd k8s/flux
git -C "$HOMELAB_VALUES" pull
tf init
tf apply
```

Ein Durchlauf genügt, auch gegen einen frischen Cluster. Danach die drei
Bootstrap-Geheimnisse eintragen:

```bash
../../tools/sops-bootstrap
```

`tf output bootstrap` beschreibt denselben Weg von Hand, falls gerade kein
Schlüsselbund da ist.

Prüfen mit `tf output status_commands` und `tf output access`: `fluxinstance/flux`
und `GitRepository flux-system` auf `Ready`, alle Flux-Pods laufen.

## Secrets

Alle Zugangsdaten liegen SOPS-verschlüsselt im Gitea-Repo `homelab-secrets`,
nicht in diesem. Der Grund steht im Kopf von
[`clusters/talos-cp1/secrets.yaml`](clusters/talos-cp1/secrets.yaml): Dieses
Repo geht öffentlich nach GitHub, und auch Ciphertext soll dort nicht liegen.

Der Umgang damit — anlegen, ändern, Schlüssel wechseln — steht im
[README von homelab-secrets](https://git.local.nico-steinmueller.de/nico/homelab-secrets).

### Die drei Geheimnisse, die nicht aus Git kommen können

| Secret | Wert | Wofür |
|---|---|---|
| `sops-age` | die Zeile `AGE-SECRET-KEY-1…` des Arbeitsschlüssels | entschlüsselt `homelab-secrets` |
| `homelab-secrets-auth` | Gitea-Benutzer und Token, Leserecht | holt `homelab-secrets` |
| `flux-git-auth` | GitHub-PAT, `Contents: Read` | holt dieses Repo (optional, es ist öffentlich) |

Das ist keine Bequemlichkeit, sondern die Kette: Ohne `flux-git-auth` erreicht
Flux dieses Repo nicht, ohne dieses Repo kennt es `homelab-secrets` nicht, und
ohne `sops-age` könnte es dort nichts lesen. Terraform legt alle drei leer an,
`tools/sops-bootstrap` fragt sie ab und trägt sie nach — verdeckte Eingabe,
leere Eingabe lässt das jeweilige Secret unverändert.

Abgefragt und nicht aus dem Schlüsselbund gelesen, anders als bei `tools/tf`:
Das ist kein täglicher Befehl, sondern ein Handgriff bei Inbetriebnahme und
Wiederaufbau. Genau dann ist der Schlüsselbund dieser Maschine womöglich nicht
die Quelle der Wahrheit — der age-Schlüssel kann vom Wechselmedium kommen, der
PAT frisch erzeugt sein.

Nach dem Setzen zeigt das Skript den abgeleiteten Public Key an. Er muss in
`.sops.yaml` als Empfänger stehen; stimmt er nicht überein, wurde gegen einen
Schlüssel verschlüsselt, den der Cluster nicht hat.

Der age-Schlüssel liegt bewusst nicht als Datei unter `~/.config/sops`, sondern
im selben Schlüsselbund wie der Gitea-Token — ein Ort für Geheimnisse auf der
Arbeitsstation, nicht zwei. `tools/sops` reicht ihn an `sops` durch.

Die Werkzeuge dafür kommen aus dem Tools-Playbook, nicht von Hand
(`ansible/tools/group_vars/all.yml`: `age`, `sops`, `jq`):

```bash
cd ansible/tools && ansible-playbook -i inventory.ini tools.yml --ask-become-pass
```

Anlegen der beiden Schlüssel und der erste Beweisfall stehen im
[README von homelab-secrets](https://git.local.nico-steinmueller.de/nico/homelab-secrets),
Abschnitt „Einrichten".

**Der zweite Schlüssel ist der wichtige.** `.sops.yaml` trägt zwei Empfänger:
den Arbeitsschlüssel und einen Recovery-Schlüssel, der ausschließlich offline
existiert. Einen Empfänger nachträglich aufzunehmen setzt voraus, dass man
schon einen besitzt — im Verlustfall ist genau er der Unterschied zwischen
„neu setzen" und „alles verloren".

### Rotation

Wert in `homelab-secrets` ändern, committen, pushen. Flux schreibt das Secret
neu, und Reloader startet neu, was es benutzt
([`clusters/talos-cp1/reloader.yaml`](clusters/talos-cp1/reloader.yaml)) — die
Annotation dafür setzt Kyverno cluster-weit, sie muss in keinem Chart stehen.

Was dabei **nicht** passiert: die Gegenseite ändern. Ein rotiertes
Postgres-Passwort startet Nextcloud neu, und Nextcloud kommt dann nicht mehr an
die Datenbank, weil dort noch das alte gilt. Diese Hälfte gehört einem Operator,
der beide Seiten besitzt — siehe [../AUSBAUSTUFEN.md](../AUSBAUSTUFEN.md).

## Entscheidungen

**Secret leer aus Terraform.** Das Objekt existiert nur, damit
die FluxInstance einen gültigen `pullSecret`-Namen hat; `ignore_changes = [data]`
hält den per kubectl eingetragenen Wert.

**Auch die neuen Secrets leer aus Terraform.** Der ursprüngliche Grund — ein
PAT als Variable stünde im Klartext im State — trägt seit der
State-Verschlüsselung in `tools/tf` nicht mehr allein. Für den age-Schlüssel
gilt aber ein zweiter: Er ist das Geheimnis, aus dem sich alle anderen ergeben.
Ihn durch den State laufen zu lassen machte die State-Passphrase zu seinem
Vorhängeschloss — eine Abhängigkeit, die man beim Wechsel der Passphrase
mitdenken müsste und dann nicht mitdenkt.

**NodePort ohne Login.** Die Status-Seite verlangt anders als Headlamp kein
Token, zeigt dafür weder Secrets noch ConfigMaps - jeder im Heimnetz sieht den
Reconciliation-Zustand. Reicht das nicht, `service_type = "ClusterIP"` und
`kubectl -n flux-system port-forward svc/flux-operator 9080:9080`.

**Kein PodSecurity `restricted` auf `flux-system`.** Kustomize- und
helm-controller müssen anwenden dürfen, was im beobachteten Pfad steht - das ist
GitOps, keine übersehene Härtung. Die Kontrolle liegt darin, wer auf
`var.git_branch` schreiben darf.

**`cluster.multitenant = false`.** Ein einzelner Autor schreibt auf den Branch.
`true` schränkt kustomize-controller auf Service-Accounts pro Namespace ein -
sinnvoll, sobald mehrere Repos oder Autoren auf den Cluster schreiben.

## Workloads

`clusters/talos-cp1/` enthält whoami (lokales Chart), Headlamp, metrics-server
und Reloader (fremde Charts) sowie in `secrets.yaml` die zweite Git-Quelle -
Details im
[README dort](clusters/talos-cp1/README.md).
