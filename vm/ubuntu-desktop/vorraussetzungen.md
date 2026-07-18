sudo apt update
sudo apt install -y qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils cloud-image-utils

# Deinen Benutzer der libvirt-Gruppe hinzufügen (danach einmal neu einloggen!)
sudo adduser $USER libvirt
sudo adduser $USER kvm



# Command zzum bauen von ISO-Images
sudo apt update && sudo apt install -y genisoimage


# Terraform als "echter" Libvirt-Nutzer ausführen

Wenn du terraform apply ausführst, stellt Terraform die Verbindung zu qemu:///system her. Damit Libvirt die vom Provider erstellten Dateien korrekt für den libvirt-qemu-Nutzer freigibt, füge deinen eigenen Ubuntu-Nutzer zur kvm- und libvirt-Gruppe hinzu (falls im ersten Schritt etwas nicht gegriffen hat):
Bash

sudo usermod -aG libvirt,kvm,render $USER

Wichtig: Damit diese Gruppenänderung aktiv wird, musst du dich einmal vom Ubuntu-Host abmelden und neu anmelden (oder den PC neu starten).

# AppArmor blockiert Basis-Images (Permission denied auf base.qcow2)

Das war der härteste Gegner. Wenn Terraform virtuelle Festplatten klont (ein sogenanntes "Backing-File" nutzt), erstellt Libvirt für die neue VM ein strenges AppArmor-Sicherheitsprofil. Dieses Profil hat standardmäßig "vergessen", der VM auch das Lesen der zugrundeliegenden Basis-Datei zu erlauben.

    Die Lösung: Die systemweite AppArmor-Abstraktion für QEMU anpassen.
    In der Datei /etc/apparmor.d/abstractions/libvirt-qemu mussten ganz unten diese zwei Zeilen hinzugefügt werden:
    Plaintext

    /var/lib/libvirt/images/ r,
    /var/lib/libvirt/images/** rwk,

    Danach AppArmor und Libvirt neu laden:
    Bash

    sudo systemctl restart apparmor
    sudo systemctl restart libvirtd