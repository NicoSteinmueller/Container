# Flux (GitOps)

Push auf `var.git_branch` rollt aus, ohne `kubectl apply` von Hand - dieselbe
Automatik, die Portainer für die Compose-Stacks liefert. Das Modul installiert
Flux Operator und eine `FluxInstance`, die dieses Repo beobachtet.

| | |
|---|---|
| Quelle | `k8s/flux/clusters/talos-cp1` aus diesem Repo (`sync_path`) |
| Zugang | Flux-Status-Seite, NodePort `30081`, ohne Login |
| Secrets | `homelab-secrets` (Gitea), SOPS-verschlüsselt |
| Bootstrap | drei Secrets, leer angelegt, von Hand befüllt (drei `kubectl patch`) |

## Anwenden

State **und** Werte liegen in Gitea

```bash
cd k8s/flux
git -C "$HOMELAB_VALUES" pull
tf init
tf apply
```

Ein Durchlauf genügt, auch gegen einen frischen Cluster. Danach die drei
Bootstrap-Geheimnisse eintragen — die Befehle dafür stehen unter
[Secrets](#die-drei-geheimnisse-die-nicht-aus-git-kommen-können).

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
die Werte trägt man von Hand nach.

Von Hand und nicht aus dem lokalen Bestand gelesen, anders als bei `tools/tf`:
Das ist kein täglicher Befehl, sondern ein Handgriff bei Inbetriebnahme und
Wiederaufbau. Genau dann ist der Bestand dieser Maschine womöglich nicht die
Quelle der Wahrheit — der age-Schlüssel kann vom Wechselmedium kommen, der PAT
frisch erzeugt sein. Ein Skript, das diesen Handgriff versteckt, müsste
gepflegt werden für drei Befehle, die man im Leben eines Clusters zweimal tippt.

Die Werte gehören in den Befehl, jeder an die Stelle des Platzhalters. Sie
stehen damit in der Shell-Historie und, während der Befehl läuft, in der
Prozessliste — bei einer Neuinstallation hinnehmbar, andernfalls die Zeile mit
einem führenden Leerzeichen beginnen (`HISTCONTROL=ignorespace`) und die
Historie danach durchsehen.

**1. `sops-age`** — erwartet wird die eine Zeile ab `AGE-SECRET-KEY-1`, nicht
die ganze Datei aus `age-keygen`. Der Schlüsselname muss auf `.agekey` enden,
danach sucht kustomize-controller:

```bash
kubectl -n flux-system patch secret sops-age --type=merge \
  -p '{"stringData":{"identity.agekey":"AGE-SECRET-KEY-1..."}}'
```

Gegenprobe — der öffentliche Teil muss in `.sops.yaml` als Empfänger stehen:

```bash
echo 'AGE-SECRET-KEY-1...' | age-keygen -y -
```

Stimmt er nicht überein, wurde gegen einen Schlüssel verschlüsselt, den der
Cluster nicht hat; die Kustomization scheitert dann mit `no matching identity`.

**2. `homelab-secrets-auth`** — Benutzername und ein Token mit Leserecht auf
`nico/homelab-secrets`:

```bash
kubectl -n flux-system patch secret homelab-secrets-auth --type=merge \
  -p '{"stringData":{"username":"<gitea-user>","password":"<gitea-token>"}}'
```

**3. `flux-git-auth`** — optional, im Normalfall zu überspringen: Das Repo ist
öffentlich. Der PAT hält den Weg offen, falls es das einmal nicht mehr ist, und
hebt das Ratelimit an (fein-scoped auf `NicoSteinmueller/Container`,
`Contents: Read`):

```bash
kubectl -n flux-system patch secret flux-git-auth --type=merge \
  -p '{"stringData":{"username":"git","password":"<github-pat>"}}'
```

Danach zieht Flux innerhalb seines Intervalls von selbst nach. Sofort:

```bash
kubectl -n flux-system annotate --overwrite gitrepository/homelab-secrets \
  reconcile.fluxcd.io/requestedAt="$(date +%s)"
```

Der age-Schlüssel liegt unter `~/.config/sops/age/keys.txt` — dort, wo sops von
allein sucht. `tools/sops` setzt deshalb nichts, ein blankes `sops` tut dasselbe;
der Wrapper prüft nur vorab auf fehlende Binary und fehlenden Schlüssel, weil
sops dafür nur ein knappes "no keys found" liefert.

Die Werkzeuge dafür kommen aus dem Tools-Playbook, nicht von Hand
(`ansible/tools/group_vars/all.yml`: `age`, `sops`):

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
