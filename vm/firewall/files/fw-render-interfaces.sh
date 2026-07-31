#!/bin/sh
#
# Löst die MAC-Adressen aus /etc/firewall/interfaces.map in Interface-Namen auf
# und schreibt daraus die nft-Defines, die /etc/nftables.nft einbindet.
#
# Hintergrund: Der Kernel vergibt eth0..eth3 in PCI-Reihenfolge. Das ist bei
# libvirt zwar stabil, aber nichts, worauf ein Regelsatz mit vier Segmenten
# stillschweigend bauen sollte - eine vertauschte Zuordnung wäre eine Firewall,
# die etwas anderes tut als das, was im Repo steht.
#
# Schlägt die Auflösung fehl, bricht das Skript ab. /etc/init.d/firewall lädt
# dann den Panic-Regelsatz, statt mit einem halb passenden Ruleset zu starten.
#
set -eu

MAP=/etc/firewall/interfaces.map
OUT=/etc/nftables.d/interfaces.nft

mac_to_ifname() {
  _mac=$(echo "$1" | tr 'A-Z' 'a-z')
  for _dev in /sys/class/net/*; do
    [ -e "$_dev/address" ] || continue
    if [ "$(cat "$_dev/address")" = "$_mac" ]; then
      basename "$_dev"
      return 0
    fi
  done
  return 1
}

[ -r "$MAP" ] || { echo "fw-render-interfaces: $MAP fehlt" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

{
  echo "# Automatisch erzeugt von fw-render-interfaces - nicht bearbeiten."
  echo "# Quelle: $MAP"
} > "$tmp"

while read -r name mac; do
  case "$name" in
    ''|\#*) continue ;;
  esac

  if ! ifname=$(mac_to_ifname "$mac"); then
    echo "fw-render-interfaces: kein Interface mit MAC $mac ($name)" >&2
    exit 1
  fi

  echo "define $name = \"$ifname\"" >> "$tmp"
done < "$MAP"

install -m 0644 "$tmp" "$OUT"
