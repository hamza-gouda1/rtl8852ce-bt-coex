#!/usr/bin/env bash
# Phase-2 live experiment: measure BT delivery stalls per coex policy.
# Requires the otree-dbg build with btc_policy_override params (swap first!).
# Keep music playing the whole time; each phase lasts ~50 s.
# Usage: sudo bash btc-policy-test.sh
set -u
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DIR="$SCRIPT_DIR/policy-test-$(date +%H%M%S)"
mkdir -p "$DIR"
PARAM=/sys/module/rtw89_core/parameters/btc_policy_override
W1=/sys/module/rtw89_core/parameters/btc_w1_dur_ms

phase() {
    echo "[*] Phase: $1 (policy=$2, w1_ms=$3) -- keep the music playing!"
    echo "$3" > "$W1"
    echo "$2" > "$PARAM"
    timeout 50 btmon -w "$DIR/$1.btmon" 2>/dev/null
    sleep 2
}

[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

phase 1-baseline-auto   -1   20
phase 2-tdw1b1-w5ms    1283   5
phase 3-pauto-tdw1b1   1539   5
phase 4-off-bt            0  20
phase 5-restore-auto    -1   20

echo "[*] Done -> $DIR"
ls -la "$DIR"
echo "Report back; each phase gets a stall-count analysis."
