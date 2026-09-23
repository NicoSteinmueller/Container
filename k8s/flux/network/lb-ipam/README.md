# lb-ipam

| | tut | eingeschaltet über |
|---|---|---|
| **LB-IPAM** (`IPPool.yaml`) | *vergibt* eine Adresse an einen Service | genügt, dass der Pool existiert |
| **L2-Announcement** (`L2Announcement.yaml`) | *kündigt* sie per ARP im LAN an | `l2announcements.enabled` in [cilium.yaml.tftpl](../../../../vm/talos/values/cilium.yaml.tftpl) |

- **Fehlt die Ankündigung**, steht `EXTERNAL-IP` da und niemand erreicht sie.
  Gegenprobe ist die Lease, nicht der Service.
- **Nicht per `kubectl patch cm cilium-config`** einschalten: Das setzt nur das
  Flag, nicht die RBAC auf Leases (`… is forbidden`).
- **Welcher Service welche Adresse** bekommt, steht als
  `lbipam.cilium.io/ips` am Service - ohne sie könnten die beiden
  Ingress-Adressen nach einem Neustart tauschen.
- Die L2-Policy kennt in Cilium 1.20 **kein `v2`** - beim Update prüfen.

```bash
kubectl -n kube-system get lease | grep l2announce
kubectl get ciliumloadbalancerippools,ciliuml2announcementpolicies
```
