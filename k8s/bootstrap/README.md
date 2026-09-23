# Flux-Bootstrap

OpenTofu-Modul, das Flux **einmal** in den Cluster bringt: Operator,
FluxInstance und drei leere Secrets. Was Flux danach anwendet:
[`../flux/`](../flux/README.md) ab `k8s/flux/sync` (`sync_path`).

```bash
cd k8s/bootstrap
git -C "$HOMELAB_VALUES" pull     # Werte und State liegen in Gitea
tf init && tf apply               # ein Durchlauf, auch gegen einen frischen Cluster
tf output status_commands         # fluxinstance/flux und GitRepository auf Ready
```

## Die drei Geheimnisse

| Secret | Wert | Wofür |
|---|---|---|
| `sops-age` | Zeile `AGE-SECRET-KEY-1…` des Arbeitsschlüssels | entschlüsselt `homelab-secrets` |
| `homelab-secrets-auth` | Gitea-Benutzer und Token mit Leserecht | holt `homelab-secrets` |
| `flux-git-auth` | GitHub-PAT, `Contents: Read` | holt dieses Repo - optional, es ist öffentlich |

Tofu legt sie leer an (`ignore_changes = [data]`), die Werte kommen von Hand:
Das passiert nur bei Inbetriebnahme und Wiederaufbau, und genau dann kommt der
Schlüssel womöglich vom Wechselmedium statt von dieser Maschine. Den
age-Schlüssel nicht durch den State zu schicken hält ihn außerdem unabhängig von
der State-Passphrase. Zeilen mit führendem Leerzeichen beginnen, dann bleiben sie
aus der Shell-Historie (`HISTCONTROL=ignorespace`).

```bash
# Schlüsselname muss auf .agekey enden
kubectl -n flux-system patch secret sops-age --type=merge \
  -p '{"stringData":{"identity.agekey":"AGE-SECRET-KEY-1..."}}'
echo 'AGE-SECRET-KEY-1...' | age-keygen -y -   # muss in .sops.yaml stehen, sonst "no matching identity"

kubectl -n flux-system patch secret homelab-secrets-auth --type=merge \
  -p '{"stringData":{"username":"<gitea-user>","password":"<gitea-token>"}}'

kubectl -n flux-system patch secret flux-git-auth --type=merge \
  -p '{"stringData":{"username":"git","password":"<github-pat>"}}'
kubectl -n flux-system annotate --overwrite gitrepository/homelab-secrets \
  reconcile.fluxcd.io/requestedAt="$(date +%s)"
```

- Der age-Schlüssel liegt unter `~/.config/sops/age/keys.txt`, wo sops von
  selbst sucht; sops und age kommen aus `ansible/tools`.
- **Der Recovery-Schlüssel ist der wichtige:** `.sops.yaml` hat zwei Empfänger,
  der zweite existiert nur offline. Ohne ihn ist ein verlorener
  Arbeitsschlüssel alles verloren.

## Entscheidungen

- **Status-Seite per NodePort `30081`**, begrenzt auf die Verwaltungsrechner
  (`web_source_cidrs`). Die Talos-Firewall greift dort nicht - NodePorts bedient
  Cilium im eBPF-Datapath -, die NetworkPolicy ist die einzige Stufe.
- **Zum NodePort gehört eine eigene NetworkPolicy**
  (`flux_web_nodeport`, gleiche `count`-Bedingung): Die des Charts lässt nur
  clusterinterne Identitäten auf 9080, ein Browser ist `world`. Fehlerbild ist
  ein Timeout bei gesundem Service.
- **Nicht über `ingress-internal`:** Traefik bräuchte Secrets-Rechte in
  `flux-system`, wo `sops-age` liegt. Ohne sie reißt der fehlgeschlagene Informer
  *alle* Routen des Controllers mit (ausprobiert: überall 404). Notweg:
  `kubectl -n flux-system port-forward svc/flux-operator 9080:9080`.
- **Keine Pod-Security-Stufe auf `flux-system`**: Die Controller müssen anwenden
  dürfen, was im Repo steht. Die Kontrolle ist, wer auf `var.git_branch`
  schreibt.
- **`multitenant: false`**, ein Autor. `true` lohnt erst mit mehreren Repos
  oder Autoren.
