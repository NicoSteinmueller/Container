# Ansible-Helfer

Playbooks zur Einrichtung von Ubuntu/Debian-Hosts. Alle Befehle werden aus
diesem Verzeichnis heraus ausgefuehrt.

Fuer die VM-Provisionierung selbst siehe [../vm/](../vm/) - die libvirt-VMs
entstehen dort per Terraform, nicht ueber Ansible.

## Ansible bereitstellen

Einmalig auf einem frischen Host, bevor die Playbooks laufen koennen:

```bash
./install-ansible.sh
```

## Tools (empfohlen fuer neue Software)

[tools/](tools/) enthaelt ein allgemeines Playbook, das den Soll-Zustand
mehrerer Tools aus einer einzigen Liste herstellt und fuer jedes installierte
Tool automatische Updates einrichtet. Neue Software gehoert dorthin - die
Einzel-Playbooks unten bleiben nur wegen ihrer bestehenden Nutzung.

```bash
cd tools && ansible-playbook -i inventory.ini tools.yml
```

## Minikube

Installiert Docker, Minikube, kubectl und Helm, startet den Cluster mit Calico
als CNI, aktiviert die Addons und traegt die Ingress-Hosts in `/etc/hosts` ein.
Das Playbook laeuft ausschliesslich gegen `localhost` und braucht daher kein
Inventar.

```bash
ansible-playbook minikube-install.yml
```

Die Versionen von Minikube und kubectl sind im Playbook gepinnt. Die
kubectl-Version ist mit `kubernetes_version` in
[../vm/talos/variables.tf](../vm/talos/variables.tf) abgestimmt, damit Dev und
Cluster dieselbe Kubernetes-Version fahren - beide stehen derzeit auf 1.36.3.
Beim Anheben einer der beiden Zahlen gehoert die andere mitgeprueft.

Neu nach Kubernetes migrierte Dienste in der Variable `k8s_local_hosts`
ergaenzen - der `/etc/hosts`-Eintrag wird bei jedem Lauf aktualisiert.

Deinstallation loescht Cluster, Binaries, Konfigurationsordner im Home und den
`/etc/hosts`-Block:

```bash
ansible-playbook minikube-uninstall.yml
```
