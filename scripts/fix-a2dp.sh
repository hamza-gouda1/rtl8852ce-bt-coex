#!/usr/bin/env bash
# Fixes the stuck "no A2DP / handsfree only" state without unpairing.
# Root cause: bluetoothd caches the device's A2DP SEP (stream endpoint) info;
# after audio-stack restarts the local codec endpoints no longer match the
# cache -> 'Unable to select SEP'. Restarting bluetoothd clears the cache
# (pairing is preserved; the speaker reconnects after).
set -u
DEV=98:47:44:A0:D1:65

echo "[*] Disconnecting speaker ..."
bluetoothctl disconnect "$DEV" >/dev/null 2>&1
sleep 2

echo "[*] Stopping user audio stack ..."
systemctl --user stop wireplumber pipewire pipewire-pulse

echo "[*] Restarting bluetoothd (needs sudo -- clears the SEP cache) ..."
sudo systemctl restart bluetooth
sleep 2

echo "[*] Starting user audio stack ..."
systemctl --user start pipewire pipewire-pulse wireplumber
sleep 3

echo "[*] Reconnecting speaker ..."
bluetoothctl connect "$DEV" 2>&1 | tail -1
sleep 6

echo "[*] Card profiles now:"
pactl list cards 2>/dev/null | sed -n '/bluez_card/,/^$/p' | grep -iE 'a2dp-sink|head-unit|audio-gateway|Active' | sed 's/^[[:space:]]*/    /'

echo "[*] If an a2dp-sink profile is listed and Active -> play music."
