# local-path

- **`/var/mnt/local-path`** ist nicht frei gewählt: Talos mountet User-Volumes
  unter `/var/mnt/<name>`. 

## Verwaiste Volumes

`Retain` heißt: Ein gelöschtes PVC hinterlässt ein PV auf `Released` samt
Verzeichnis - etwa nach dem Neuinstallieren eines Charts. Aufräumen, wenn
sicher ist, dass nichts davon gebraucht wird: auf `Delete` stellen, dann löscht
der Provisioner Verzeichnis und PV selbst (Helper-Pod), ohne Zugriff auf den
Node.

```bash
kubectl get pv | grep Released
talosctl -n <node-ip> list -r /var/mnt/local-path/<pv>_<ns>_<pvc>   # was liegt drin?
kubectl patch pv <pv> -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}'
```
