# Ansible-Helfer

Playbooks zur Einrichtung von Ubuntu/Debian-Hosts. Alle Befehle werden aus
diesem Verzeichnis heraus ausgefuehrt.

Fuer die VM-Provisionierung selbst siehe [../vm/](../vm/) (Terraform) und
[../vm-ansible/](../vm-ansible/) (libvirt-VMs anlegen).

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

## Terraform

Das Playbook richtet das HashiCorp-apt-Repository ein und installiert das Paket
`terraform`.

```bash
ansible-playbook -i inventory.ini terraform-install.yml
```

Fuer einen Ad-hoc-Lauf gegen den lokalen Host ohne Inventar:

```bash
ansible-playbook -i 'localhost,' -c local terraform-install.yml
```

Deinstallation entfernt Paket, Repository und Signing-Key:

```bash
ansible-playbook -i inventory.ini terraform-uninstall.yml
```

Soll das Repository erhalten bleiben (z. B. wegen anderer HashiCorp-Pakete wie
Vault oder Packer):

```bash
ansible-playbook -i inventory.ini terraform-uninstall.yml \
  -e terraform_remove_repository=false
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
kubectl-Version ist mit [../vm/talos-test/](../vm/talos-test/) abgestimmt, damit
Dev und Test dieselbe Kubernetes-Version fahren.

Neu nach Kubernetes migrierte Dienste in der Variable `k8s_local_hosts`
ergaenzen - der `/etc/hosts`-Eintrag wird bei jedem Lauf aktualisiert.

Deinstallation loescht Cluster, Binaries, Konfigurationsordner im Home und den
`/etc/hosts`-Block:

```bash
ansible-playbook minikube-uninstall.yml
```

## Dateien

| Datei                     | Zweck                                              |
| ------------------------- | -------------------------------------------------- |
| `tools/`                  | Allgemeines Playbook inkl. automatischer Updates    |
| `install-ansible.sh`      | Ansible selbst auf einem frischen Host installieren |
| `inventory.ini`           | Inventar (aktuell nur `localhost`)                  |
| `terraform-install.yml`   | Terraform installieren                              |
| `terraform-uninstall.yml` | Terraform entfernen                                 |
| `minikube-install.yml`    | Minikube-Stack installieren und starten             |
| `minikube-uninstall.yml`  | Minikube-Stack entfernen                            |
| `notes.md`                | Lose Notizen zu interessanten CNCF-Projekten        |
