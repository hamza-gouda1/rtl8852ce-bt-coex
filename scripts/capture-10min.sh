#!/usr/bin/env bash
# Phase-1 capture (10 minutes) against the debugfs-enabled rtw89 build:
#   hci.btmon / hci.txt : full Bluetooth HCI trace (stutters = measurable gaps)
#   traffic.log         : every 2 s -> WiFi rx/tx bytes, signal, BT sink errors
#   coex_state.log      : every 5 s -> /sys/kernel/debug/rtw89/btc_info snapshots
# Keep music playing and use the laptop normally (agent working = traffic).
# The bgscan clear at the start is runtime-only and self-reverts.
set -uo pipefail
STAMP=$(date +%H%M%S)
DIR="$HOME/projects/rtw89-btc/phase1-capture-$STAMP"
mkdir -p "$DIR"
IFACE=wlp108s0
DBG=/sys/kernel/debug/rtw89

echo "[*] Clearing wpa_supplicant bgscan for the capture window ..."
NETID=$(sudo wpa_cli -i "$IFACE" list_networks 2>/dev/null | awk '/\[CURRENT\]/{print $1; exit}')
if [ -n "${NETID:-}" ]; then
    sudo wpa_cli -i "$IFACE" set_network "$NETID" bgscan '""' >/dev/null
    echo "    bgscan off for this connection (runtime only)."
else
    echo "    (no current network found -- skipping bgscan clear)"
fi

echo "[*] Starting HCI trace + samplers (600 s) ..."
sudo timeout 610 btmon -w "$DIR/hci.btmon" &
( while true; do
    TS=$(date +%s.%N)
    R=$(grep "$IFACE" /proc/net/dev | awk '{print $2, $10}')
    SIG=$(iw dev "$IFACE" link 2>/dev/null | awk '/signal/{print $2; exit}')
    ERR=$(timeout 3 pw-top -bn 1 2>/dev/null | grep bluez_output | awk '{print $9}')
    echo "$TS rx=${R%% *} tx=${R##* } signal=$SIG sink_err=$ERR" >> "$DIR/traffic.log"
    sleep 2
  done ) &
S1=$!
( while true; do
    echo "=== $(date +%s.%N) ===" >> "$DIR/coex_state.log"
    sudo cat "$DBG/btc_info" >> "$DIR/coex_state.log" 2>&1
    sleep 5
  done ) &
S2=$!

echo "[*] Capturing 600 seconds -- music on, normal usage, let it stutter ..."
sleep 600
kill "$S1" "$S2" 2>/dev/null
sudo pkill -f 'btmon -w' 2>/dev/null
sleep 1
sudo chown "$USER:$USER" "$DIR/hci.btmon" 2>/dev/null

echo "[*] Final snapshots ..."
{ echo "=== final btc_info $(date) ==="; sudo cat "$DBG/btc_info"; } >> "$DIR/coex_state.log"
sudo dmesg | grep -iE 'rtw89|bluetooth|hci0' | tail -50 > "$DIR/dmesg-tail.txt"

echo "[*] Decoding HCI trace ..."
btmon -r "$DIR/hci.btmon" > "$DIR/hci.txt" 2>/dev/null

echo "[*] Done -> $DIR"
ls -la "$DIR"
echo "Report back and I will run the correlation analysis."
