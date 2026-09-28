# lb-ipam

| | tut | eingeschaltet über |
|---|---|---|
| **LB-IPAM** (`IPPool.yaml`) | *vergibt* eine Adresse an einen Service | genügt, dass der Pool existiert |
| **L2-Announcement** (`L2Announcement.yaml`) | *kündigt* sie per ARP im LAN an | `l2announcements.enabled` in [cilium.yaml.tftpl](../../../../vm/talos/values/cilium.yaml.tftpl) |
