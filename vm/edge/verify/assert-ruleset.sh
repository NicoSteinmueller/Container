#!/usr/bin/env bash
#
# Prüft, dass auf der Edge-VM exakt der Stand läuft, der im Repo steht.
#
# Die VM liegt außerhalb des GitOps-Flows - es gibt also nichts, was eine
# Handänderung von selbst zurückdrehen würde. Dieses Skript ist der Ersatz
# dafür: drei unabhängige Prüfungen.
#
#   1. Datei-Drift:  /etc/nftables.conf und die sshd-Ergänzung gegen die
#                    Terraform-Outputs
#   2. Lauf-Drift:   der geladene Regelsatz gegen das, was die Datei erzeugt
#   3. Laufzeit:     sysctl-Härtung, Dienste, lauschende Sockets
#
# Prüfung 2 lädt die Datei in eine wegwerfbare Network-Namespace und vergleicht
# die kanonische Ausgabe mit der laufenden. Damit fällt auch auf, wenn jemand
# per `nft add rule` etwas dazugelegt hat, ohne die Datei anzufassen.
#
# Aufruf:
#
#   vm/edge/verify/assert-ruleset.sh [user@host]
#
set -euo pipefail

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tf() { terraform -chdir="$MODULE_DIR" output -raw "$1"; }

TARGET="${1:-$(tf ssh_target)}"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10 "$TARGET")

#
# Die Diffs landen unter einem zufälligen Namen, nicht unter einem festen Pfad
# in /tmp: Ein vorbereiteter Symlink an einer vorhersagbaren Stelle würde die
# Umleitung in eine beliebige Datei schreiben lassen.
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

compare() {
  local label="$1" expected="$2" actual="$3"

  # Bewusst eine eigene Zeile: bash expandiert alle Wörter einer
  # local-Anweisung, bevor es sie ausführt - ein ${label} in derselben Zeile
  # sähe die Variable noch nicht und liefe unter `set -u` in einen Abbruch.
  local out="$workdir/${label//\//_}.diff"

  if diff -u <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") > "$out"; then
    ok "$label entspricht dem Repo"
  else
    bad "$label weicht ab:"
    sed 's/^/        /' "$out"
  fi
}

# ---------------------------------------------------------------------
info "1/3  Datei-Drift"

compare "/etc/nftables.conf" "$(tf nftables_ruleset)" "$("${SSH[@]}" sudo cat /etc/nftables.conf)"
compare "/etc/ssh/sshd_config.d/99-edge.conf" "$(tf sshd_config)" "$("${SSH[@]}" sudo cat /etc/ssh/sshd_config.d/99-edge.conf)"

#
# Traefik- und CrowdSec-Konfiguration über Prüfsummen statt über Diffs: Es sind
# rund zwanzig Dateien, und was hier zählt, ist die Frage "auf der Maschine
# bearbeitet statt im Repo?" - nicht die einzelne Zeile.
#
digests="$(terraform -chdir="$MODULE_DIR" output -json stack_file_digests 2>/dev/null || echo '{}')"
paths="$(python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin).keys()))' <<<"$digests")"

if [[ -n "$paths" ]]; then
  remote_digests="$("${SSH[@]}" "sudo sha256sum $(tr '\n' ' ' <<<"$paths") 2>/dev/null" || true)"

  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    want="$(python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$path" <<<"$digests")"
    have="$(awk -v p="$path" '$2 == p {print $1}' <<<"$remote_digests")"

    if [[ -z "$have" ]]; then
      bad "$path fehlt auf der VM"
    elif [[ "$want" != "$have" ]]; then
      bad "$path weicht vom Repo ab"
    fi
  done <<<"$paths"

  [[ $fail -eq 0 ]] && ok "$(wc -l <<<"$paths") Dateien der Stufen 2-6 entsprechen dem Repo"
fi

# ---------------------------------------------------------------------
info "2/3  Lauf-Drift: geladene Tabelle gegen die Datei"

#
# Verglichen wird nur `table inet edge`. Die Tabelle des CrowdSec-Bouncers
# gehört bewusst nicht dazu: Ihr Inhalt ändert sich mit jeder Entscheidung der
# LAPI und wäre in einem Drift-Vergleich nur Rauschen.
#
canonical="$("${SSH[@]}" 'sudo sh -s' <<'REMOTE'
set -eu
ns="edgecheck-$$"
cleanup() { ip netns del "$ns" >/dev/null 2>&1 || true; }
trap cleanup EXIT
ip netns add "$ns"
ip netns exec "$ns" nft -f /etc/nftables.conf
ip netns exec "$ns" nft -s list table inet edge
REMOTE
)"

live="$("${SSH[@]}" sudo nft -s list table inet edge)"

compare "geladener Regelsatz" "$canonical" "$live"

# ---------------------------------------------------------------------
info "3/3  Laufzeitzustand"

remote_cat() { "${SSH[@]}" "cat $1 2>/dev/null || echo MISSING"; }

check_sysctl() {
  local path="$1" want="$2" label="$3"
  local have
  have="$(remote_cat "$path")"
  if [[ "$have" == "$want" ]]; then
    ok "$label"
  else
    bad "$label - $path = $have (erwartet: $want)"
  fi
}

# Die Edge-VM ist ein Proxy, kein Router. Stünde hier 1, gäbe es einen zweiten
# Weg von außen nach innen, an TLS, WAF und CrowdSec vorbei.
check_sysctl /proc/sys/net/ipv4/ip_forward 0 "ip_forward aus"
check_sysctl /proc/sys/net/ipv4/conf/all/rp_filter 1 "rp_filter strikt"
check_sysctl /proc/sys/net/ipv6/conf/all/disable_ipv6 1 "IPv6 abgeschaltet"
check_sysctl /proc/sys/kernel/dmesg_restrict 1 "dmesg_restrict"

for unit in nftables ssh chrony; do
  if "${SSH[@]}" systemctl is-active --quiet "$unit"; then
    ok "$unit läuft"
  else
    bad "$unit läuft nicht"
  fi
done

# Traefik nur prüfen, wenn er ausgerollt ist (stack_enabled).
if "${SSH[@]}" test -x /usr/local/bin/traefik; then
  if "${SSH[@]}" systemctl is-active --quiet traefik; then
    ok "traefik läuft ($("${SSH[@]}" /usr/local/bin/traefik version | awk '/^Version:/ {print $2}'))"
  else
    bad "traefik ist installiert, läuft aber nicht - journalctl -u traefik"
  fi
fi

#
# Ein Docker-Daemon auf dieser Maschine würde ip_forward auf 1 setzen und damit
# die Proxy-statt-Router-Entscheidung unterlaufen - der Grund, warum Traefik
# hier als Binary läuft.
#
if "${SSH[@]}" "command -v dockerd >/dev/null 2>&1"; then
  bad "dockerd ist installiert - siehe README, Abschnitt 'Warum Binaries statt Docker'"
else
  ok "kein Docker-Daemon vorhanden"
fi

#
# Lauschende Sockets. Erwartet werden genau zwei Adressen: SSH auf dem LAN-Bein
# und - sobald Traefik läuft - 443 ebendort. Alles andere auf 0.0.0.0 ist ein
# Fund: Es wäre über die Portfreigabe potenziell aus dem Internet erreichbar.
#
info "Lauschende Sockets"
listen="$("${SSH[@]}" 'sudo ss -lntuH' | awk '{print $1, $5}' | sort -u)"
printf '%s\n' "$listen" | sed 's/^/        /'

lan_ip="$(tf lan_ip)"
if printf '%s\n' "$listen" | grep -qE '(^|[[:space:]])(0\.0\.0\.0|\*):(22|443)'; then
  bad "Ein Dienst lauscht auf allen Adressen statt nur auf $lan_ip"
else
  ok "Kein Dienst auf 0.0.0.0 für 22/443"
fi

echo
if [[ $fail -eq 0 ]]; then
  printf '\033[32mKein Drift.\033[0m\n'
else
  printf '\033[31mDrift gefunden - die Edge-VM entspricht nicht dem Repo.\033[0m\n'
fi
exit $fail
