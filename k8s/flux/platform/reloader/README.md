# reloader

Startet neu, was ein geändertes Secret benutzt - sonst arbeitet ein Pod nach
einer Rotation mit dem alten Wert weiter.

- **`autoReloadAll: true`**: Im Blickfeld gilt jeder Workload als annotiert.
- **Blickfeld ist eine Namespace-Liste** (`watchGlobally: false`): `crowdsec`,
  `monitoring`, `traefik-internal`, `traefik-public`. Das Chart legt dann nur
  Roles an, keine ClusterRole - sonst dürfte Reloader Workloads in jedem
  Namespace patchen, `kube-system` eingeschlossen.
- **Ein neuer Dienst mit Secret gehört in die Liste**, sonst läuft er nach einer
  Rotation still mit dem alten Wert weiter.
- Die **Gegenseite** ändert Reloader nicht: Ein rotiertes DB-Passwort startet
  die Anwendung neu, die Datenbank kennt aber noch das alte.

```bash
kubectl get clusterrole,clusterrolebinding | grep reloader   # erwartet: leer
kubectl -n reloader logs deploy/reloader-reloader | tail
```
