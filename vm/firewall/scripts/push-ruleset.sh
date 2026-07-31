#!/usr/bin/env bash
#
# Rollt einen geänderten Regelsatz auf die laufende Firewall aus.
#
# Warum nicht `terraform apply`: Cloud-Init wendet seine Module nur bei einer
# neuen instance-id an, also erst nach einem Reboot. Für eine Regeländerung ist
# ein Reboot unnötig - die VM ist in dem Moment aber das einzige Gateway für
# DMZ und Cluster.
#
# Ablauf: rendern -> auf der VM syntaktisch prüfen -> installieren ->
# Service neu starten -> Drift-Prüfung. Scheitert das Laden, zieht
# /etc/init.d/firewall den Panic-Regelsatz und die VM bleibt über das
# Management-Netz erreichbar.
#
# Aufruf:
#
#   vm/firewall/scripts/push-ruleset.sh [user@host]
#
set -euo pipefail

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-$(terraform -chdir="$MODULE_DIR" output -raw ssh_target)}"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10 "$TARGET")

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

echo "Rendere Regelsatz aus $MODULE_DIR ..."
terraform -chdir="$MODULE_DIR" output -raw nftables_ruleset > "$tmp"

echo "Übertrage nach $TARGET ..."
scp -q "$tmp" "$TARGET:/tmp/nftables.nft.new"

echo "Prüfe Syntax auf der VM ..."
"${SSH[@]}" 'sudo nft -c -f /tmp/nftables.nft.new'

echo "Installiere und lade neu ..."
"${SSH[@]}" 'sudo install -o root -g root -m 0640 /tmp/nftables.nft.new /etc/nftables.nft && sudo rm -f /tmp/nftables.nft.new && sudo rc-service firewall restart'

echo
"$MODULE_DIR/verify/assert-ruleset.sh" "$TARGET"

cat <<'EOT'

Regelsatz ist ausgerollt. Danach fällig:

  sudo vm/firewall/verify/egress-test.sh
  sudo vm/firewall/verify/egress-test.sh --segment cluster

EOT
