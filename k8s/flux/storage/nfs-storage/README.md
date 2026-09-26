# nfs-storage

`csi-driver-nfs` plus StorageClass `nfs-unraid`. Je PVC ein Verzeichnis
`/mnt/user/k8s/<namespace>/<pvc-name>`. Mit `onDelete: retain` findet ein neues
PVC gleichen Namens seine Daten wieder - ohne statische PVs.

Keine Egress-Policy: Beide Pods laufen auf hostNetwork, keine Policy griffe.

## Auf dem Unraid-Host (von Hand)

1. Array stoppen, *Settings → NFS* → **Enable NFS**, Array starten.
2. Share `k8s` anlegen.
3. *Shares → k8s → NFS Security*: **Export = Yes**, Regel
   `192.168.178.230(sec=sys,rw,no_root_squash)`.
