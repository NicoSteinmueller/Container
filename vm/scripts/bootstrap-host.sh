#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if ! command -v ansible-playbook >/dev/null 2>&1; then
  "${SCRIPT_DIR}/install-ansible.sh"
fi

sudo -v
sudo ansible-playbook \
  -i "${VM_DIR}/inventory.ini" \
  -c local \
  "${VM_DIR}/ansible/install_terraform.yml"

