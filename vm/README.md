# Terraform: Ubuntu Server VM auf KVM/libvirt

Dieses Verzeichnis erstellt eine Ubuntu-Server-VM auf einem Ubuntu-Host mit KVM/libvirt ueber Terraform.

## Voraussetzungen

- Ubuntu Host mit KVM/libvirt (`qemu-kvm`, `libvirt-daemon-system`, `virtinst`)
- Aktiver libvirt-Dienst
- Terraform >= 1.5
- Ein oeffentlicher SSH-Key auf dem Host (Standard: `~/.ssh/id_ed25519.pub`)

## Schnellstart

```bash
cd /home/nico/Repos/Containers/vm
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform plan
terraform apply
```

## Hilfsskripte

- `ansible/install_terraform.yml`: installiert Terraform auf Ubuntu/Debian
- `scripts/install-ansible.sh`: installiert Ansible auf Ubuntu/Debian
- `inventory.ini`: lokales Inventory mit festem Python-Interpreter

## Alles auf dem Host einrichten

```bash
cd /home/nico/Repos/Containers/vm
bash scripts/bootstrap-host.sh
```

Wenn dein Benutzer kein passwordless sudo hat, rufe das Playbook direkt mit `sudo` oder `--ask-become-pass` auf:

```bash
cd /home/nico/Repos/Containers/vm
sudo ansible-playbook -i inventory.ini -c local ansible/install_terraform.yml
# oder
ansible-playbook -i inventory.ini -c local --ask-become-pass ansible/install_terraform.yml
```

## SSH auf die VM

Nach `terraform apply` wird die IP als Output angezeigt:

```bash
terraform output vm_ip_addresses
ssh nico@<IP-ADRESSE>
```

## Wichtige Variablen

- `vm_name`: Name der VM
- `vm_user`: Benutzer, der via cloud-init erzeugt wird
- `ssh_public_key_path`: Public-Key fuer Login
- `memory_mb` / `vcpu_count`: VM-Ressourcen
- `root_disk_size_bytes`: Root-Disk-Groesse in Bytes
- `network_name`: libvirt Netzwerkname
- `storage_pool`: libvirt Storage-Pool
- `ubuntu_image_url`: Ubuntu Cloud Image

## Aufraeumen

```bash
terraform destroy
```

