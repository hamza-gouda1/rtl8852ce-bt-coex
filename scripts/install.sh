#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Install the permanent RTL8852CE Bluetooth/Wi-Fi coexistence fix.
# Part of rtl8852ce-bt-coex by Hamza Gouda (GPL-2.0)
#
#   1. bt-afh-guard daemon + systemd service (always)
#   2. PipeWire AAC codec plugin (if built first with scripts/build-aac-plugin.sh)
#
# Safe to run while Wi-Fi is in use: it never touches the network stack.
# Usage: sudo bash scripts/install.sh
set -euo pipefail
[ "$EUID" -eq 0 ] || { echo "Run with sudo"; exit 1; }
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
for p in hcitool hciconfig iw; do command -v $p >/dev/null || { echo "[FAIL] missing '$p' (apt install bluez iw)"; exit 1; }; done

# 1) AFH guard
install -m 0755 "$REPO/scripts/bt-afh-guard" /usr/local/sbin/bt-afh-guard
install -m 0644 "$REPO/systemd/bt-afh-guard.service" /etc/systemd/system/bt-afh-guard.service
systemctl daemon-reload
systemctl enable --now bt-afh-guard.service
sleep 6
echo "[ok] bt-afh-guard: $(systemctl is-active bt-afh-guard)"
journalctl -t bt-afh-guard -n 1 -o cat --no-pager || true

# 2) AAC plugin (optional)
SO="$REPO/build-aac/libspa-codec-bluez5-aac.so"
DEST_DIR=$(dirname "$(find /usr/lib -path '*spa-0.2/bluez5/libspa-codec-bluez5-sbc.so' 2>/dev/null | head -1)")
if [ -f "$SO" ] && [ -d "$DEST_DIR" ]; then
    BUILT_FOR=$(cat "$REPO/build-aac/PIPEWIRE_VERSION" 2>/dev/null || echo "?")
    NOW=$(pipewire --version | grep -oP 'libpipewire \K[0-9.]+' | head -1)
    if [ "$BUILT_FOR" != "$NOW" ]; then
        echo "[skip] AAC plugin was built for PipeWire $BUILT_FOR but $NOW is installed -- rebuild first"
    else
        install -m 0644 "$SO" "$DEST_DIR/libspa-codec-bluez5-aac.so"
        echo "[ok] AAC plugin installed -> $DEST_DIR"
        echo "     Activate it: put the earbuds in their case, then run"
        echo "     'sudo systemctl restart bluetooth' and take them out again"
        echo "     (do NOT restart PipeWire mid-stream -- see docs/SOLUTION.md, Troubleshooting)."
    fi
else
    echo "[i] AAC plugin not built -- skipped (optional: bash scripts/build-aac-plugin.sh)"
fi

# 3) Show the hop map the connected headphones actually use (HCI Read AFH Channel Map)
H=$(hcitool con 2>/dev/null | grep -oP 'handle \K[0-9]+' | head -1 || true)
if [ -n "$H" ]; then
    echo "[i] Live link AFH map (byte 7 onward = channel bitmap, 1 = in use):"
    hcitool cmd 0x05 0x0006 "$(printf '0x%02X' "$H")" 0x00 | tail -1
fi
echo "DONE"
