#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# wifi-health-capture.sh — sample Wi-Fi link health and the A2DP transport
# state every 2 s into one CSV, to measure the Bluetooth -> Wi-Fi direction
# the repository had not looked at before: does audio streaming coincide with
# Wi-Fi beacon loss, retries and disconnects on this card?
#
# Usage: bash scripts/wifi-health-capture.sh <seconds> [IFACE]
#   <seconds>   capture duration (e.g. 600)
#   [IFACE]     wireless interface (default: the first from `iw dev`)
#
# Root is NOT needed, with two caveats documented in HARDWARE-TEST.md:
#   - wpa_supplicant events come from journalctl; reading them requires the
#     invoking user to be in the systemd-journal/adm group. Without journal
#     access the events column stays empty (everything else still works).
#   - pactl must run as the desktop user: under sudo it cannot see the
#     user's audio session, so A2DP would read UNKNOWN.
set -u

DURATION=${1:?usage: wifi-health-capture.sh <seconds> [IFACE]}
case "$DURATION" in
    ''|*[!0-9]*) echo "duration must be a positive integer (seconds)" >&2; exit 2 ;;
esac
IFACE=${2:-}
if [ -z "$IFACE" ]; then
    IFACE=$(iw dev 2>/dev/null | awk '/Interface/{print $2; exit}')
fi
[ -n "$IFACE" ] || { echo "no wireless interface found" >&2; exit 1; }

STAMP=$(date +%Y%m%d-%H%M%S)
OUT="wifi-health-$STAMP.csv"

# --- wpa_supplicant event spool (BEACON-LOSS / DISCONNECTED / CONNECTED) ---
EVFILE=$(mktemp)
JPID=""
cleanup() {
    [ -n "$JPID" ] && kill "$JPID" 2>/dev/null
    rm -f "$EVFILE"
}
trap cleanup EXIT

JPID=""
if command -v journalctl >/dev/null 2>&1; then
    journalctl -f -n 0 -o json 2>/dev/null \
        | grep --line-buffered -E 'BEACON-LOSS|DISCONNECTED|CTRL-EVENT-CONNECTED' > "$EVFILE" &
    JPID=$!
fi
LAST_EV=0
drain_events() {   # print the events seen since the last drain, "; "-joined (may be empty)
    local total evs=""
    total=$(wc -l < "$EVFILE" 2>/dev/null) || total=0
    total=${total//[!0-9]/}
    if [ "${total:-0}" -gt "$LAST_EV" ]; then
        evs=$(sed -n "$((LAST_EV + 1)),${total}p" "$EVFILE" \
              | grep -oE 'BEACON-LOSS|DISCONNECTED|CTRL-EVENT-CONNECTED' | sort -u | tr '\n' ';')
        LAST_EV=$total
    fi
    echo "$evs"
}

# --- A2DP transport state from the user session (pactl) ---
a2dp_state() {
    local states
    states=$(pactl list sinks short 2>/dev/null | grep bluez | awk '{print $NF}' | sort -u | tr '\n' ',')
    if [[ "$states" == *RUNNING* ]]; then
        echo "RUNNING"
    elif [[ "$states" == *SUSPENDED* ]]; then
        echo "SUSPENDED"
    elif [ -n "$states" ]; then
        echo "OTHER"
    else
        echo "UNKNOWN"
    fi
}

# --- sampling loop ---
echo "ts,signal_dbm,tx_kbits,rx_kbits,tx_retries,tx_failed,beacon_loss,rx_drop_misc,tx_packets,rx_packets,a2dp,wifi_event" > "$OUT"
echo "[*] capturing $DURATION s on $IFACE every 2 s -> $OUT"
echo "[*] keep audio playing / stopped per the protocol; journal events: $( [ -n "$JPID" ] && echo on || echo unavailable )"
END=$(( $(date +%s) + DURATION ))
while [ "$(date +%s)" -lt "$END" ]; do
    TS=$(date +%s)
    LINK=$(iw dev "$IFACE" link 2>/dev/null)
    ST=$(iw dev "$IFACE" station dump 2>/dev/null)

    SIG=$(awk '/signal:/{print $2; exit}' <<<"$LINK")
    TXKBIT=$(awk '/tx bitrate:/{printf "%d", $3 * 1000; exit}' <<<"$LINK")
    RXKBIT=$(awk '/rx bitrate:/{printf "%d", $3 * 1000; exit}' <<<"$LINK")

    TXRETRY=$(grep -m1 'tx retries:' <<<"$ST" | awk '{print $NF}')
    TXFAILED=$(grep -m1 'tx failed:' <<<"$ST" | awk '{print $NF}')
    BEACON_LOSS=$(grep -m1 'beacon loss:' <<<"$ST" | awk '{print $NF}')
    RXDROP=$(grep -m1 'rx drop misc:' <<<"$ST" | awk '{print $NF}')
    TXPKTS=$(grep -m1 'tx packets:' <<<"$ST" | awk '{print $NF}')
    RXPKTS=$(grep -m1 'rx packets:' <<<"$ST" | awk '{print $NF}')

    EV=$(drain_events)
    echo "$TS,${SIG:-},${TXKBIT:-},${RXKBIT:-},${TXRETRY:-},${TXFAILED:-},${BEACON_LOSS:-},${RXDROP:-},${TXPKTS:-},${RXPKTS:-},$(a2dp_state),$EV" >> "$OUT"
    sleep 2
done

echo "[*] done -> $OUT ($(wc -l < "$OUT") lines incl. header)"
echo "[*] analyze: python3 scripts/analyze-wifi-health.py $OUT"
