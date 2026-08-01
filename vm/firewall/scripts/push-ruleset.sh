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

#
# Übertragen, prüfen und installieren passieren in *einem* privilegierten
# Aufruf, und die Zwischendatei liegt unter einem zufälligen Namen in /etc
# statt unter /tmp/nftables.nft.new:
#
#   - Ein fester Pfad in einem für alle beschreibbaren Verzeichnis lässt sich
#     zwischen `nft -c` und `install` austauschen. Geprüft würde dann etwas
#     anderes als das, was in /etc/nftables.nft landet.
#   - /etc ist ausschließlich für root beschreibbar. Damit gibt es keinen
#     Moment, in dem der künftige Regelsatz an einer Stelle liegt, an die ein
#     unprivilegierter Prozess herankommt.
#
payload="$(base64 < "$tmp" | tr -d '\n')"

echo "Übertrage nach $TARGET, prüfe Syntax und installiere ..."
"${SSH[@]}" 'sudo sh -s' <<REMOTE
set -eu
umask 077
staging=\$(mktemp /etc/nftables.nft.new.XXXXXX)
trap 'rm -f "\$staging"' EXIT
printf %s '$payload' | base64 -d > "\$staging"
nft -c -f "\$staging"
install -o root -g root -m 0640 "\$staging" /etc/nftables.nft
rc-service firewall restart
REMOTE

echo
"$MODULE_DIR/verify/assert-ruleset.sh" "$TARGET"

cat <<'EOT'

Regelsatz ist ausgerollt. Danach fällig:

  sudo vm/firewall/verify/egress-test.sh
  sudo vm/firewall/verify/egress-test.sh --segment cluster

EOT
