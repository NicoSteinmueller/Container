# nfs-storage

`csi-driver-nfs` plus StorageClass `nfs-unraid`. Je PVC ein Verzeichnis
`/mnt/user/k8s/<namespace>/<pvc-name>`. Mit `onDelete: retain` findet ein neues
PVC gleichen Namens seine Daten wieder - ohne statische PVs.

Keine Egress-Policy: Beide Pods laufen auf hostNetwork, keine Policy griffe.

## Über WireGuard

NFS mit `sec=sys` meldet sich nicht an - der Export vertraut der
Quelladresse. Deshalb läuft NFS durch einen WireGuard-Tunnel zwischen Node und Host.


## Auf dem Unraid-Host (von Hand)

1. Array stoppen, *Settings → NFS* → **Enable NFS**, Array starten.
2. Share `k8s` anlegen.
3. Den Tunnel aufsetzen, siehe [vm/talos](../../../../vm/talos/README.md#nfs-über-wireguard).
4. *Shares → k8s → NFS Security*: **Export = Yes**, Regel
   `10.253.0.2(sec=sys,rw,no_root_squash)`