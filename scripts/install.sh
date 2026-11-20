#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Install the permanent RTL8852CE Bluetooth/Wi-Fi coexistence fix.
# Part of rtl8852ce-bt-coex by Hamza Gouda (GPL-2.0)
#
#   1. bt-afh-guard daemon + verified HCI sender + systemd service (always)
#   2. PipeWire AAC codec plugin (if built first with scripts/build-aac-plugin.sh)
#
# Safe to run while Wi-Fi is in use: it never touches the network stack.
# Usage: sudo bash scripts/install.sh   (override the controller with HCI=hci1 ...)
set -euo pipefail
[ "$EUID" -eq 0 ] || { echo "Run with sudo"; exit 1; }
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

for p in iw python3; do
    command -v "$p" >/dev/null 2>&1 || { echo "[FAIL] missing '$p' (apt install iw python3)"; exit 1; }
done
if ! command -v hcitool >/dev/null 2>&1 && [ ! -x "$REPO/scripts/hci-cmd.py" ]; then
    echo "[FAIL] need bluez hcitool or scripts/hci-cmd.py as the verified HCI sender backend"
    exit 1
fi
HCI=${HCI:-hci0}

# Version drift check: report what is installed vs what the repo ships.
REPO_V=$(sed -n 's/^GUARD_VERSION="\{0,1\}\([0-9.]*\)"\{0,1\}$/\1/p' "$REPO/scripts/bt-afh-guard" | head -1)
INSTALLED_V=$(sed -n 's/^GUARD_VERSION="\{0,1\}\([0-9.]*\)"\{0,1\}$/\1/p' /usr/local/sbin/bt-afh-guard 2>/dev/null | head -1)
[ -n "$INSTALLED_V" ] || INSTALLED_V="?"
if [ "$INSTALLED_V" = "?" ]; then
    echo "[i] installed daemon has no version stamp (pre-1.1 copy) -- it will be replaced"
elif [ "$INSTALLED_V" != "$REPO_V" ]; then
    echo "[i] replacing bt-afh-guard $INSTALLED_V with $REPO_V"
fi

# Source the daemon for the verified sender (hci_backend / hci_send) so the
# logic exists exactly once, in scripts/bt-afh-guard.
# shellcheck disable=SC1091
WANT_HCI=$HCI
source "$REPO/scripts/bt-afh-guard"
HCI=$WANT_HCI   # the sourced defaults must not override the caller's choice

if [ ! -d "/sys/class/bluetooth/$HCI" ]; then
    echo "[FAIL] controller $HCI not present in /sys/class/bluetooth/"
    exit 1
fi
hci_backend || true
if [ -z "$HCI_BACKEND" ]; then
    echo "[FAIL] no verified HCI backend available"
    exit 1
fi
echo "[i] verified HCI sender backend: $HCI_BACKEND"

if hci_send "$HCI" 0x04 0x0001 >/dev/null; then
    echo "[ok] controller $HCI answers HCI commands"
else
    echo "[FAIL] controller $HCI does not answer HCI commands (down, or rfkill blocked?)"
    exit 1
fi

# 1) AFH guard + verified sender
install -m 0755 "$REPO/scripts/bt-afh-guard" /usr/local/sbin/bt-afh-guard
install -m 0755 -D "$REPO/scripts/hci-cmd.py" /usr/local/lib/bt-afh-guard/hci-cmd.py
install -m 0644 "$REPO/systemd/bt-afh-guard.service" /etc/systemd/system/bt-afh-guard.service
systemctl daemon-reload
systemctl enable bt-afh-guard.service
# restart, not "enable --now": an already-running older daemon keeps executing
# its old in-memory copy and the old unit's sandboxing until it is restarted.
STARTED=$(date '+%Y-%m-%d %H:%M:%S')
systemctl restart bt-afh-guard.service
sleep 6
echo "[ok] bt-afh-guard: $(systemctl is-active bt-afh-guard) (pid $(systemctl show -p MainPID --value bt-afh-guard))"
NEW_LOG=$(journalctl -t bt-afh-guard --since "$STARTED" -o cat --no-pager 2>/dev/null || true)
if [ -n "$NEW_LOG" ]; then
    sed 's/^/     /' <<<"$NEW_LOG"
else
    echo "[!] the restarted daemon has not logged yet -- check: journalctl -t bt-afh-guard -f"
fi

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

# 3) Show the hop map each connected device actually uses (HCI Read AFH Channel Map)
read -r LO HI <<<"$(wifi_block)"
LIVE=$(report_live_maps "$LO" "$HI")
if [ -n "$LIVE" ]; then
    echo "[i] Live link AFH maps (Wi-Fi block ${LO:-none}-${HI:-none} MHz):"
    sed 's/^/     /' <<<"$LIVE"
else
    echo "[i] no connected Bluetooth link -- connect the earbuds, then run: sudo bt-afh-guard --status"
fi
echo "DONE"
