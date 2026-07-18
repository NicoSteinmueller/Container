#!/usr/bin/env bash
set -euo pipefail

if ! command -v apt-get >/dev/null 2>&1; then
  echo "Dieses Script ist fuer Debian/Ubuntu-Systeme mit apt-get gedacht." >&2
  exit 1
fi

if [[ $EUID -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
fi

export DEBIAN_FRONTEND=noninteractive

$SUDO apt-get update
$SUDO apt-get install -y software-properties-common ca-certificates curl gnupg lsb-release

if ! command -v ansible-playbook >/dev/null 2>&1; then
  $SUDO apt-add-repository --yes --update ppa:ansible/ansible
  $SUDO apt-get install -y ansible
fi

ansible --version

