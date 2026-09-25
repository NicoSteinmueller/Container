# local-path

`local-path-provisioner` von Rancher auf der zweiten Disk der VM. Chart aus einer
`GitRepository` auf einen Tag - Rancher veröffentlicht ihn nur im Git.

- **`/var/mnt/local-path`** ist nicht frei gewählt: Talos mountet User-Volumes
  unter `/var/mnt/<name>`. Muss zum Volume-Namen in
  [uservolume.yaml.tftpl](../../../../vm/talos/patches/uservolume.yaml.tftpl)
  passen.
- **`WaitForFirstConsumer`**: Das Volume ist ein Verzeichnis auf genau einem
  Node - eine falsche Einstellung fiele erst beim zweiten auf.
- **Die Disk** entsteht mit `tofu apply` in `vm/talos`, ist aber erst nach dem
  **nächsten Start der VM** sichtbar.

```bash
talosctl -n <node-ip> get disks               # vda und vdb
talosctl -n <node-ip> get volumestatus        # u-local-path ready
talosctl -n <node-ip> get volumestatus u-local-path -o yaml   # bei Pending: errorMessage
```

`vdb` da und trotzdem `Pending`? Der Fehler steht nur in `volumestatus`; nach
außen scheitert der Helper-Pod an `read-only file system`.

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
