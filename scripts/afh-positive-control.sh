#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# afh-positive-control.sh — positive control for the AFH causal claim.
#
# The 2026-11-08 controlled rerun was inconclusive because BOTH host
# classifications produced live maps with zero Wi-Fi overlap: the mechanism
# was never actually exercised. This test deliberately creates overlap:
#
#   open       - host hint: all 79 channels usable
#   restricted - the guard's mask: the Wi-Fi block avoided
#   confined   - the v0.1 inverted mask: ONLY channels inside the Wi-Fi block
#                usable (requires >= 20 channels inside the block, else the
#                phase is refused)
#
# After each classification the earbuds are reconnected so a fresh link
# negotiates a new hop map; the live map is read back before and after the
# load; a 30 s ICMP load (1200-byte payload, one request every 8 ms, bound to
# Wi-Fi, aimed at the gateway) matches the 2026-11-08 rerun profile; and
# outgoing ACL gaps > 50 ms are counted from a btmon trace of the same
# connection, the way the capture-10min.sh harness records HCI data.
#
# The phases share one order (open -> restricted -> confined); with one run
# per phase this is a directed comparison, not a balanced A/B.
#
# Usage: sudo bash scripts/afh-positive-control.sh [IFACE] [HANDLE]
# Requires root: btmon, raw HCI sends, ping intervals below 2 ms.
set -u

IFACE=${1:-$(iw dev 2>/dev/null | awk '/Interface/{print $2; exit}')}
[ -n "$IFACE" ] || { echo "no wireless interface" >&2; exit 1; }
HCI=${HCI:-hci0}
LOAD_S=30

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Reuse the daemon's verified sender and mask logic (sourced, not duplicated).
# shellcheck disable=SC1091
source "$HERE/bt-afh-guard"
hci_backend || true
[ -n "$HCI_BACKEND" ] || { echo "no verified HCI backend" >&2; exit 1; }

read -r lo hi <<<"$(wifi_block)"
[ -n "$lo" ] || { echo "no 2.4 GHz Wi-Fi link -- connect to the 2.4 GHz AP first" >&2; exit 1; }
echo "[*] Wi-Fi block: $lo-$hi MHz (from $(iw dev "$IFACE" info 2>/dev/null | grep -m1 channel))"

RESTRICTED=$(build_mask "$lo" "$hi")

# confined = only the channels inside the Wi-Fi block usable (the v0.1 polarity).
confined_mask() {
    local nlo=$(( lo - 2402 )) nhi=$(( hi - 2402 )) n out="" b
    (( nlo < 0 )) && nlo=0
    (( nhi > 78 )) && nhi=78
    local -a M=(0 0 0 0 0 0 0 0 0 0)
    for ((n = nlo; n <= nhi; n++)); do M[n/8]=$(( M[n/8] | (1 << (n%8)) )); done
    for b in "${M[@]}"; do out+=" $(printf '0x%02X' "$b")"; done
    echo "${out# }"
}
CONFINED=$(confined_mask)
CONF_USABLE=$(mask_usable_count "$CONFINED")
if [ "$CONF_USABLE" -lt 20 ]; then
    echo "[FAIL] confined mask invalid for this Wi-Fi block ($CONF_USABLE usable channels < 20)" >&2
    echo "       use a channel plan with >= 20 BT channels inside the block (e.g. 40 MHz on ch 5 or 11)" >&2
    exit 1
fi
echo "[*] masks: restricted=$RESTRICTED  confined=$CONFINED ($CONF_USABLE ch inside)"

HANDLE=${2:-}
[ -n "$HANDLE" ] || HANDLE=$(list_acl_handles | head -1)
[ -n "$HANDLE" ] || { echo "[FAIL] no connected ACL link -- connect the earbuds first" >&2; exit 1; }
echo "[*] measuring ACL handle $HANDLE"

DIR="$HERE/positive-control-$(date +%H%M%S)"
mkdir -p "$DIR"

# --- ACL gap counting from the decoded btmon text ---
tx_seconds() {   # $1 = decoded btmon text, $2 = handle -> ACL TX timestamps in seconds (one per line)
    awk -v h="$2" '
        $0 ~ /[Aa][Cc][Ll] [Dd]ata TX/ && $0 ~ ("handle " h "([^0-9]|$)") {
            ts = ""
            for (i = NF; i >= 1; i--)
                if ($i ~ /^[0-9][0-9][:.][0-9][0-9][:.][0-9][0-9]\.[0-9][0-9][0-9][0-9][0-9][0-9]$/) { ts = $i; break }
            if (ts != "") {
                split(ts, t, /[:.]/)
                printf "%.6f\n", t[1] * 3600 + t[2] * 60 + t[3] + t[4] / 1000000
            }
        }' "$1"
}

gap_stats() {   # $1 = tx timestamps file, $2 = label -> prints "gaps p95_ms max_ms"
    local gaps="$DIR/$2-gaps.txt"
    awk 'NR == 1 { prev = $1; next }
         { d = $1 - prev; prev = $1; if (d > 0.05) print d }' "$1" > "$gaps"
    local n p95 mx
    n=$(wc -l < "$gaps")
    p95=$(sort -n "$gaps" | awk -v n="$n" 'NR == int(n * 0.95 + 0.999999) { printf "%.1f", $1 * 1000; exit }')
    mx=$(sort -n "$gaps" | tail -1 | awk '{ printf "%.1f", $1 * 1000 }')
    echo "$n ${p95:-0.0} ${mx:-0.0}"
}

# --- one phase: set classification, reconnect, load, measure ---
run_phase() {   # $1 = name, $2 = mask
    local name=$1 mask=$2
    echo
    echo "=== phase: $name ==="
    # shellcheck disable=SC2086  # the mask MUST be word-split into 10 separate hex arguments
    if ! hci_send "$HCI" 0x03 0x003F $mask >/dev/null; then
        echo "[FAIL] $name classification rejected: status ${HCI_STATUS:-no verdict}" >&2
        exit 1
    fi
    echo "[*] host classification set. Put the earbuds in their case, take them out, wait for the"
    echo "    connection, then press Enter."
    read -r _

    echo "[*] live map before load:"
    report_live_maps "$lo" "$hi"

    btmon -w "$DIR/$name.btmon" & MON=$!
    sleep 1
    local GW
    GW=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
    [ -n "$GW" ] || { echo "[FAIL] no default gateway for the ICMP load" >&2; kill "$MON"; exit 1; }
    echo "[*] ICMP load: $LOAD_S s, 1200-byte payload @ 8 ms, via $IFACE to $GW -- music playing!"
    timeout "$LOAD_S" ping -q -i 0.008 -s 1200 -I "$IFACE" "$GW" > "$DIR/$name-ping.txt" 2>&1
    kill -INT "$MON" 2>/dev/null; wait "$MON" 2>/dev/null

    btmon -r "$DIR/$name.btmon" > "$DIR/$name.txt" 2>/dev/null
    tx_seconds "$DIR/$name.txt" "$HANDLE" > "$DIR/$name-tx.txt"
    read -r NGAPS P95 MX <<<"$(gap_stats "$DIR/$name-tx.txt" "$name")"
    local TXN
    TXN=$(wc -l < "$DIR/$name-tx.txt")
    echo "[*] result ($name): TX ACL packets=$TXN  gaps>50ms=$NGAPS  p95=${P95}ms  max=${MX}ms"
    echo "[*] live map after load:"
    report_live_maps "$lo" "$hi"
}

echo "[*] positive control: 3 phases, order fixed (open -> restricted -> confined)"
run_phase open "$ALL_USABLE"
run_phase restricted "$RESTRICTED"
run_phase confined "$CONFINED"

echo
echo "=== summary ==="
for p in open restricted confined; do
    read -r NGAPS P95 MX <<<"$(gap_stats "$DIR/$p-tx.txt" "$p")"
    printf '%-10s gaps>50ms=%-4s p95=%sms max=%sms\n' "$p" "$NGAPS" "$P95" "$MX"
done
echo
echo "Raw traces: $DIR (btmon files, decoded text, tx timestamps, ping output)."
echo "If the bt-afh-guard service is running it re-applies its own mask within one cycle."
