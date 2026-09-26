# storage

Aufgeteilt nach **Zugriffsmuster**.

| | [`local-path/`](local-path) (Default) | [`nfs-storage/`](nfs-storage) |
|---|---|---|
| wofür | fsync und Locking: DBs, Indizes, Queues | Bestände: Medien, Uploads, Backups |
| liegt auf | zweite Disk der VM, `/var/mnt/local-path` | Share `k8s` |
| Zugriff | `ReadWriteOnce` | `ReadWriteMany` |
| PVC gelöscht | `Retain` | `onDelete: retain` |
| Backup | **keins** - verschwindet mit der VM | über Host |
