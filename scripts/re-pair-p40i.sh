#!/usr/bin/env bash
# Remove + re-pair the soundcore P40i (the known-good ritual, scripted).
# Run this, then when it says so, hold the speaker's Bluetooth button until
# it enters pairing mode (sound / blinking LED).
set -u
DEV=98:47:44:A0:D1:65

echo "[*] Removing device (clears pairing + service cache) ..."
bluetoothctl remove "$DEV" 2>&1 | tail -1
bluetoothctl disconnect "$DEV" >/dev/null 2>&1

echo "[*] Scanning for 45 s -- put the P40i in PAIRING MODE now"
echo "    (hold its Bluetooth button ~4 s until it beeps / LED blinks) ..."
timeout 50 bluetoothctl --timeout 45 scan on >/dev/null 2>&1

echo "[*] Pairing ..."
bluetoothctl pair "$DEV" 2>&1 | tail -2
sleep 1
bluetoothctl trust "$DEV" 2>&1 | tail -1
sleep 1
bluetoothctl connect "$DEV" 2>&1 | tail -1
sleep 6

echo "[*] Card profiles after re-pair:"
pactl list cards 2>/dev/null | sed -n '/bluez_card/,/^$/p' | grep -iE 'a2dp-sink|head-unit|audio-gateway|Active' | sed 's/^[[:space:]]*/    /'

echo "[*] Active codec (want sbc_xq):"
pw-dump 2>/dev/null | grep -o '"api.bluez5.codec": "[^"]*"' | sort | uniq -c

echo "[*] If a2dp-sink is Active with sbc_xq -> run the 10-min capture."
