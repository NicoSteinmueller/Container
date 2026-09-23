# Flux-Bootstrap

Das OpenTofu-Modul, das Flux **einmal** in den Cluster bringt: Operator,
FluxInstance und die drei Secrets, ohne die Flux nichts holen kann. Was Flux
danach **dauernd** anwendet, steht in [`../flux/`](../flux/README.md).

| | |
|---|---|
| Quelle | [`k8s/flux/sync/`](../flux/sync) aus diesem Repo (`sync_path`) |
| Zugang | Flux-Status-Seite, NodePort `30081`, auf die Admin-Adressen begrenzt |
| Secrets | `homelab-secrets` (Gitea), SOPS-verschlüsselt |
| Bootstrap | drei Secrets, leer angelegt, von Hand befüllt |

## Anwenden

State **und** Werte liegen in Gitea:

```bash
cd k8s/bootstrap
git -C "$HOMELAB_VALUES" pull
tf init
tf apply
```

Ein Durchlauf genügt, auch gegen einen frischen Cluster. Danach die drei
Bootstrap-Geheimnisse eintragen (siehe unten). Prüfen mit
`tf output status_commands` und `tf output access`: `fluxinstance/flux` und
`GitRepository flux-system` auf `Ready`, alle Flux-Pods laufen.

## Die drei Geheimnisse, die nicht aus Git kommen können

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
frisch erzeugt sein. Ein Skript dafür müsste gepflegt werden für drei Befehle,
die man im Leben eines Clusters zweimal tippt.

Die Werte stehen damit in der Shell-Historie und, während der Befehl läuft, in
der Prozessliste — bei einer Neuinstallation hinnehmbar, andernfalls die Zeile
mit einem führenden Leerzeichen beginnen (`HISTCONTROL=ignorespace`).

**1. `sops-age`** — erwartet wird die eine Zeile ab `AGE-SECRET-KEY-1`, nicht die
ganze Datei aus `age-keygen`. Der Schlüsselname muss auf `.agekey` enden, danach
sucht kustomize-controller:

```bash
kubectl -n flux-system patch secret sops-age --type=merge \
  -p '{"stringData":{"identity.agekey":"AGE-SECRET-KEY-1..."}}'

# Gegenprobe - der oeffentliche Teil muss in .sops.yaml als Empfaenger stehen
echo 'AGE-SECRET-KEY-1...' | age-keygen -y -
```

Stimmt er nicht überein, wurde gegen einen Schlüssel verschlüsselt, den der
Cluster nicht hat; die Kustomization scheitert mit `no matching identity`.

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

# Sofort nachziehen statt auf das Intervall zu warten
kubectl -n flux-system annotate --overwrite gitrepository/homelab-secrets \
  reconcile.fluxcd.io/requestedAt="$(date +%s)"
```

Der age-Schlüssel liegt unter `~/.config/sops/age/keys.txt` — dort, wo sops von
allein sucht. `tools/sops` setzt deshalb nichts; der Wrapper prüft nur vorab auf
fehlende Binary und fehlenden Schlüssel, weil sops dafür nur ein knappes „no keys
found" liefert. Die Werkzeuge kommen aus dem Tools-Playbook, nicht von Hand:

```bash
cd ansible/tools && ansible-playbook -i inventory.ini tools.yml --ask-become-pass
```

**Der zweite Schlüssel ist der wichtige.** `.sops.yaml` trägt zwei Empfänger: den
Arbeitsschlüssel und einen Recovery-Schlüssel, der ausschließlich offline
existiert. Einen Empfänger nachträglich aufzunehmen setzt voraus, dass man schon
einen besitzt — im Verlustfall ist genau er der Unterschied zwischen „neu setzen"
und „alles verloren".

## Entscheidungen

**Die drei Secrets leer aus Terraform.** Das Objekt existiert nur, damit die
FluxInstance einen gültigen `pullSecret`-Namen hat; `ignore_changes = [data]`
hält den per kubectl eingetragenen Wert. Der ursprüngliche Grund — ein PAT als
Variable stünde im Klartext im State — trägt seit der State-Verschlüsselung in
`tools/tf` nicht mehr allein. Für den age-Schlüssel gilt aber ein zweiter: Er ist
das Geheimnis, aus dem sich alle anderen ergeben. Ihn durch den State laufen zu
lassen machte die State-Passphrase zu seinem Vorhängeschloss — eine Abhängigkeit,
die man beim Wechsel der Passphrase mitdenken müsste und dann nicht mitdenkt.

**NodePort, aber eng.** Die Status-Seite verlangt anders als Headlamp kein Token,
zeigt dafür weder Secrets noch ConfigMaps. Erreichbar unter
`http://192.168.178.230:30081`.

Falsch an der früheren Einstellung war nicht der NodePort, sondern
`web_source_cidrs`. Gedacht war es zweistufig: die NetworkPolicy aus
`web_source_cidrs`, dahinter die Talos-Ingress-Firewall, die `30081` nirgends
nennt. Die Firewall greift dort aber nicht — sie filtert Verkehr an
Host-Prozesse, NodePorts bedient Cilium im eBPF-Datapath. Von den zwei Stufen war
also nur eine da, und die stand auf ganz RFC 1918. Jetzt steht sie in den tfvars
auf den drei Verwaltungsrechnern.

**Zum NodePort gehören zwei Objekte, nicht eines.** Neben dem Service braucht es
`kubernetes_network_policy.flux_web_nodeport` — beide hängen an derselben
`count`-Bedingung. Grund ist eine NetworkPolicy, die das Chart mitbringt und die
9080 nur clusterinternen Identitäten öffnet. Ein Browser im Heimnetz hat keine;
für Cilium ist er `world`, und der Zugriff wird verworfen:

```
192.168.x.x:32850 (world) <> flux-system/flux-operator-…:9080 (ID:9624)
  Policy denied DROPPED (TCP Flags: SYN)
```

Sichtbar wurde das erst mit Cilium — bis dahin lief der Cluster mit Flannel, und
Flannel setzt NetworkPolicies gar nicht durch. Das Fehlerbild ist ein
**Timeout**, kein `Connection refused`; Service und Endpoint sehen dabei gesund
aus:

```bash
kubectl -n flux-system get svc,endpoints flux-operator-nodeport   # unauffällig
kubectl -n kube-system exec ds/cilium -- hubble observe --last 200 --type drop
```

**Warum nicht über `ingress-internal` mit TLS und Hostnamen?** Das war der erste
Versuch und er ist gescheitert — auf eine Art, die es wert ist, festgehalten zu
werden: **Traefik startet für jeden beobachteten Namespace einen
Secrets-Informer**, unabhängig davon, ob dort etwas ein Secret referenziert. Um
`flux-system` zu bedienen, bräuchte er `get/list/watch` auf Secrets dort — und
dort liegen `sops-age` und `flux-git-auth`.

Der Versuch, ihm eine secretfreie Rolle zu geben, endete in einem vollständigen
Ausfall: Danach lieferte *jede* Route von `ingress-internal` 404, auch `whoami`
und `dashboard` — der fehlgeschlagene Informer reißt den gesamten
Kubernetes-Provider mit, nicht nur den einen Namespace. Wer das noch einmal
versuchen will, weiß jetzt, was es kostet. Ohne Zugang zum Heimnetz geht
weiterhin auch:

```bash
kubectl -n flux-system port-forward svc/flux-operator 9080:9080
```

**Kein PodSecurity `restricted` auf `flux-system`.** Kustomize- und
helm-controller müssen anwenden dürfen, was im beobachteten Pfad steht — das ist
GitOps, keine übersehene Härtung. Die Kontrolle liegt darin, wer auf
`var.git_branch` schreiben darf.

**`cluster.multitenant = false`.** Ein einzelner Autor schreibt auf den Branch.
`true` schränkt kustomize-controller auf Service-Accounts pro Namespace ein —
sinnvoll, sobald mehrere Repos oder Autoren auf den Cluster schreiben.
