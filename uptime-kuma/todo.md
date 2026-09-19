# TODO: Push-Monitor auf den `Watchdog`-Alarm des Clusters

## Schritte

1. **Uptime Kuma starten**
2. **Monitor anlegen**, Typ **Push**. Die erzeugte URL
   (`…/api/push/<token>`) gehört nach `homelab-secrets`, nicht in dieses Repo.
3. **Alertmanager-Route umbiegen** — in den Chart-Defaults steht
   `alertname = "Watchdog"` → `receiver: 'null'`. Stattdessen ein
   `webhook_configs` auf die Push-URL. Ohne diesen Schritt passiert nichts, egal
   wie der Monitor konfiguriert ist.
4. **Egress-Regel im Cluster.** `monitoring-egress` verbietet das Heimnetz.
   Alertmanager braucht eine eigene Regel, gleiche Bauart wie die frühere
   Sync-Job-Regel, nur ein einzelnes /32 auf 443:

   ```yaml
   - toCIDRSet:
       - cidr: 192.168.178.5/32
     toPorts:
       - ports:
           - port: "443"
             protocol: TCP
   ```

`local-only` braucht keinen Eingriff: Die Middleware erlaubt `192.168.178.0/24`,
und Egress aus dem Cluster erscheint als Node-Adresse `.230`.

## Intervalle

`Watchdog` feuert dauerhaft, aber wie oft der Webhook aufgerufen wird, bestimmt
`repeat_interval` der Route. Der Heartbeat in Kuma muss deutlich länger sein,
sonst gibt es Fehlalarme.

| | |
|---|---|
| `group_interval` / `repeat_interval` | `1m` (repeat darf nicht kleiner sein als group) |
| Kuma-Heartbeat | `300s` |
| Kuma-Retries | `1` |

Schlägt nach ~10 Minuten Stille an: lang genug für einen Pod-Neustart, kurz genug,
dass ein echter Ausfall nicht bis zum Morgen unbemerkt bleibt.

## Die Falle

**Kumas eigener Benachrichtigungskanal darf nicht das ntfy im Cluster sein.**
