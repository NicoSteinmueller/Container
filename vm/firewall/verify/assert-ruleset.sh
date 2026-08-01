#!/usr/bin/env bash
#
# Prüft, dass auf der Firewall-VM exakt der Regelsatz läuft, der im Repo steht.
#
# Ersetzt die Kontrolle, die ein OPNsense-UI mitliefern würde
# (k8s/Edge-Architektur.md, Abschnitt 5: "Verifikation als Pflichtbestandteil").
# Zwei unabhängige Prüfungen:
#
#   1. Datei-Drift:  /etc/nftables.nft == `terraform output -raw nftables_ruleset`
#   2. Lauf-Drift:   geladener Regelsatz == das, was die Datei erzeugen würde
#
# Prüfung 2 lädt die Datei in eine wegwerfbare Network-Namespace und vergleicht
# die kanonische Ausgabe mit der laufenden. Damit fällt auch auf, wenn jemand
# per `nft add rule` etwas dazugelegt hat, ohne die Datei anzufassen.
#
# Aufruf (vom Hypervisor-Host, der das Management-Netz erreicht):
#
#   vm/firewall/verify/assert-ruleset.sh [user@host]
#
set -euo pipefail

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-$(terraform -chdir="$MODULE_DIR" output -raw ssh_target)}"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10 "$TARGET")

#
# Die Diffs landen unter einem zufälligen Namen, nicht unter einem festen Pfad
# in /tmp: Das Skript läuft auf dem Hypervisor typischerweise als root, und ein
# vorbereiteter Symlink an einer vorhersagbaren Stelle würde die Umleitung in
# eine beliebige Datei schreiben lassen.
#
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

fail=0

info() { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok() { printf '  \033[32mOK\033[0m    %s\n' "$*"; }
bad() {
  printf '  \033[31mDRIFT\033[0m %s\n' "$*"
  fail=1
}

# ---------------------------------------------------------------------
info "1/3  Datei-Drift: /etc/nftables.nft gegen den gerenderten Regelsatz"

expected="$(terraform -chdir="$MODULE_DIR" output -raw nftables_ruleset)"
actual="$("${SSH[@]}" sudo cat /etc/nftables.nft)"

if diff -u <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") > "$workdir/file.diff"; then
  ok "Datei entspricht dem Repo"
else
  bad "Datei weicht ab:"
  sed 's/^/        /' "$workdir/file.diff"
fi

# ---------------------------------------------------------------------
info "2/3  Lauf-Drift: geladener Regelsatz gegen die Datei"

canonical="$("${SSH[@]}" 'sudo sh -s' <<'REMOTE'
set -eu
ns="fwcheck-$$"
cleanup() { ip netns del "$ns" >/dev/null 2>&1 || true; }
trap cleanup EXIT
ip netns add "$ns"
ip netns exec "$ns" nft -f /etc/nftables.nft
ip netns exec "$ns" nft -s list ruleset
REMOTE
)"

live="$("${SSH[@]}" sudo nft -s list ruleset)"

if diff -u <(printf '%s\n' "$canonical") <(printf '%s\n' "$live") > "$workdir/live.diff"; then
  ok "Geladener Regelsatz entspricht der Datei"
else
  bad "Geladener Regelsatz weicht ab:"
  sed 's/^/        /' "$workdir/live.diff"
fi

# ---------------------------------------------------------------------
info "3/3  Laufzeitzustand"

forward="$("${SSH[@]}" cat /proc/sys/net/ipv4/ip_forward)"
[[ "$forward" == "1" ]] && ok "ip_forward aktiv" || bad "ip_forward = $forward (Firewall-Service gestartet?)"

v6="$("${SSH[@]}" cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1)"
[[ "$v6" == "1" ]] && ok "IPv6 abgeschaltet" || bad "IPv6 ist aktiv - siehe k8s/Edge-Architektur.md, Abschnitt 5"

# Die Kernel-Härtung wird von /etc/init.d/firewall vor der Freigabe des
# Forwardings angewendet. Steht sie hier nicht, ist der Service in der falschen
# Reihenfolge gestartet - und rp_filter ist das, worauf sich der Panic-Regelsatz
# verlässt, der Interfaces nur über Adressen unterscheiden kann.
rpf="$("${SSH[@]}" cat /proc/sys/net/ipv4/conf/all/rp_filter 2>/dev/null || echo 0)"
[[ "$rpf" == "1" ]] && ok "rp_filter strikt" || bad "rp_filter = $rpf (erwartet: 1)"

# Ein zugewiesener Conntrack-Helper könnte über `ct state related` eine
# Erwartung ins Heimnetz öffnen - oberhalb der DENY-Regeln.
helper="$("${SSH[@]}" cat /proc/sys/net/netfilter/nf_conntrack_helper 2>/dev/null || echo 0)"
[[ "$helper" == "0" ]] && ok "Conntrack-Helper abgeschaltet" || bad "nf_conntrack_helper = $helper (erwartet: 0)"

if "${SSH[@]}" sudo rc-service firewall status 2>/dev/null | grep -q started; then
  ok "Firewall-Service läuft"
else
  bad "Firewall-Service läuft nicht"
fi

listen="$("${SSH[@]}" sudo ss -ltnH 2>/dev/null | awk '{print $4}' | sort -u | tr '\n' ' ')"
if [[ -n "$listen" ]]; then
  printf '  \033[2mLauschende Sockets: %s\033[0m\n' "$listen"
fi

echo
if [[ $fail -eq 0 ]]; then
  printf '\033[32mKein Drift.\033[0m\n'
else
  printf '\033[31mDrift gefunden - Firewall entspricht nicht dem Repo.\033[0m\n'
fi
exit $fail
