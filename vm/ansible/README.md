# Ansible-Helfer

Dieses Verzeichnis enthaelt Playbooks zur Installation und Deinstallation von Terraform auf Ubuntu/Debian-Hosts.

## Terraform installieren

```bash
cd /home/nico/Repos/Containers/vm/ansible
ansible-playbook -i <inventory> install_terraform.yml
```

Beispiel fuer einen lokalen Host:

```bash
ansible-playbook -i 'localhost,' -c local install_terraform.yml
```

## Terraform deinstallieren

```bash
cd /home/nico/Repos/Containers/vm/ansible
ansible-playbook -i inventory.ini uninstall_terraform.yml
```

Das Playbook entfernt das Paket, das HashiCorp-Repository und den Signing-Key.
Soll das Repository erhalten bleiben (z. B. wegen anderer HashiCorp-Pakete):

```bash
ansible-playbook -i 'localhost,' -c local uninstall_terraform.yml \
  -e terraform_remove_repository=false
```

