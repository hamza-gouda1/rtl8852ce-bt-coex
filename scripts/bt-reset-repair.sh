#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Full Bluetooth controller power-cycle + re-pair ritual.
# Kills any zombie SCO/HFP session at the controller level, then re-pairs.
set -u
# Bluetooth address of your headphones/speaker: first argument or $BT_DEV.
# Find it with: bluetoothctl devices
DEV=${1:-${BT_DEV:-}}
if [ -z "$DEV" ]; then
    echo "usage: $(basename "$0") <bluetooth-address>   (or set BT_DEV)" >&2
    exit 2
fi

echo "[*] Disconnecting ..."
bluetoothctl disconnect "$DEV" >/dev/null 2>&1
sleep 1

echo "[*] Controller power-cycle (sudo) ..."
sudo btmgmt power off
sleep 2
sudo btmgmt power on
sleep 2
hciconfig hci0 | grep -E 'UP|DOWN' | sed 's/^[[:space:]]*/    /'

echo "[*] Removing pairing cache ..."
bluetoothctl remove "$DEV" 2>&1 | tail -1

echo "[*] NOW: power-cycle the speaker (hold power until off, wait 10 s, on),"
echo "    then hold its Bluetooth button until pairing mode."
echo "[*] Scanning for 60 s ..."
timeout 65 bluetoothctl --timeout 60 scan on >/dev/null 2>&1

echo "[*] Pairing ..."
bluetoothctl pair "$DEV" 2>&1 | tail -2
sleep 1
bluetoothctl trust "$DEV" 2>&1 | tail -1
sleep 1
bluetoothctl connect "$DEV" 2>&1 | tail -1
sleep 8

echo "[*] SCO counter check (was sco:10239 tonight; small count = no zombie voice):"
hciconfig hci0 | grep -E 'acl|sco' | sed 's/^[[:space:]]*/    /'

echo "[*] Card profiles:"
pactl list cards 2>/dev/null | sed -n '/bluez_card/,/^$/p' | grep -iE 'a2dp-sink|head-unit|audio-gateway|Active' | sed 's/^[[:space:]]*/    /'

echo "[*] Codec (want sbc_xq):"
pw-dump 2>/dev/null | grep -o '"api.bluez5.codec": "[^"]*"' | sort | uniq -c
