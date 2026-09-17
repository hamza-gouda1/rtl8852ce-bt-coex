#!/usr/bin/env bash
# AFH experiment v2: compute the channel mask from the LIVE WiFi frequency,
# verify A2DP is streaming, clear bgscan, then A/B test:
#   Phase A: BT avoids the WiFi channel block (via standard HCI command)
#   Phase B: mask cleared
# Usage: sudo bash afh-test2.sh    (music playing the whole time!)
set -u
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DIR="$SCRIPT_DIR/afh-test2-$(date +%H%M%S)"
mkdir -p "$DIR"
IFACE=wlp108s0
DEV=98:47:44:A0:D1:65

echo "[*] Clearing bgscan (root ctrl socket) ..."
NETID=$(sudo wpa_cli -i "$IFACE" list_networks 2>/dev/null | awk '/\[CURRENT\]/{print $1; exit}')
if [ -n "${NETID:-}" ]; then
    sudo wpa_cli -i "$IFACE" set_network "$NETID" bgscan '""' >/dev/null
    echo "    off."
fi

echo "[*] Verifying A2DP is streaming (TX ACL packet delta over 3 s) ..."
A1=$(hciconfig hci0 | grep -oP 'acl:\K[0-9]+' | sed -n '2p')
sleep 3
A2=$(hciconfig hci0 | grep -oP 'acl:\K[0-9]+' | sed -n '2p')
if [ -z "${A1:-}" ] || [ -z "${A2:-}" ]; then
    echo "[FAIL] could not read ACL counters (is hci0 up?)"
    exit 1
fi
DELTA=$(( A2 - A1 ))
echo "    TX acl delta = $DELTA packets / 3 s (streaming A2DP is typically >150)"
if [ "$DELTA" -lt 80 ]; then
    echo "[FAIL] no A2DP stream detected -- play music, or run fix-a2dp.sh first"
    exit 1
fi

FREQ=$(iw dev "$IFACE" link 2>/dev/null | awk '/freq:/{print int($2); exit}')
if [ -z "$FREQ" ]; then echo "[FAIL] no WiFi link"; exit 1; fi
echo "[*] WiFi center freq: $FREQ MHz"

declare -a M=(0 0 0 0 0 0 0 0 0 0)
NMIN=$((FREQ-2412)); NMAX=$((FREQ-2392))
(( NMIN < 0 )) && NMIN=0
(( NMAX > 78 )) && NMAX=78
for ((n=NMIN; n<=NMAX; n++)); do M[n/8]=$(( M[n/8] | (1<<(n%8)) )); done
ARGS=""
for b in "${M[@]}"; do ARGS="$ARGS $(printf '0x%02X' "$b")"; done
echo "[*] Mask avoids BT channels $NMIN..$NMAX:$ARGS"

CON=$(hcitool con)
HANDLE=$(echo "$CON" | grep -oP 'handle \K[0-9]+' | head -1)
if [ -z "$HANDLE" ]; then echo "[FAIL] speaker not connected"; exit 1; fi
H=$(printf "0x%02X 0x00" "$HANDLE")

echo "[*] Link AFH map before:"
hcitool cmd 0x03 0x0041 $H
echo "[*] Setting host AFH classification ..."
hcitool cmd 0x03 0x003F $ARGS
sleep 1
echo "[*] Link AFH map after (compare):"
hcitool cmd 0x03 0x0041 $H

echo "[*] Phase A: 45 s WITH the WiFi block masked -- listen!"
timeout 50 btmon -w "$DIR/afh-on.btmon" 2>/dev/null

echo "[*] Clearing mask ..."
hcitool cmd 0x03 0x003F 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00
sleep 1
echo "[*] Phase B: 45 s unmasked -- compare"
timeout 50 btmon -w "$DIR/afh-off.btmon" 2>/dev/null

echo "[*] Done -> $DIR"
echo "How did phase A sound vs phase B?"
