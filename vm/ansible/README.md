# Ansible-Helfer

Dieses Verzeichnis enthaelt ein Playbook zur Installation von Terraform auf Ubuntu/Debian-Hosts.

## Terraform installieren

```bash
cd /home/nico/Repos/Containers/vm/ansible
ansible-playbook -i <inventory> install_terraform.yml
```

Beispiel fuer einen lokalen Host:

```bash
ansible-playbook -i 'localhost,' -c local install_terraform.yml
```

