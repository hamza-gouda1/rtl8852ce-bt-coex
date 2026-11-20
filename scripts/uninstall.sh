#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Remove the bt-afh-guard service and the AAC plugin, and restore the
# controller's default (all channels usable) host classification.
# Part of rtl8852ce-bt-coex by Hamza Gouda (GPL-2.0)
# Usage: sudo bash scripts/uninstall.sh
set -u
[ "$EUID" -eq 0 ] || { echo "Run with sudo"; exit 1; }
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

systemctl disable --now bt-afh-guard.service 2>/dev/null
rm -f /etc/systemd/system/bt-afh-guard.service /usr/local/sbin/bt-afh-guard
rm -rf /usr/local/lib/bt-afh-guard
systemctl daemon-reload

# Reset the classification through the verified sender (sourced from the repo
# copy so the logic exists exactly once), and report the real HCI status.
if [ -f "$REPO/scripts/bt-afh-guard" ]; then
    # shellcheck disable=SC1091
    source "$REPO/scripts/bt-afh-guard"
    hci_backend || true
    # shellcheck disable=SC2086  # the mask MUST be word-split into 10 separate hex arguments
    if [ -n "$HCI_BACKEND" ] && hci_send "${HCI:-hci0}" 0x03 0x003F $ALL_USABLE >/dev/null; then
        echo "[ok] AFH host classification reset (HCI status 0x00, all channels usable)"
    elif [ -n "$HCI_BACKEND" ] && [ -n "$HCI_STATUS" ]; then
        echo "[i] AFH reset rejected: status $HCI_STATUS (controller may keep the restricted map until restart)"
    else
        echo "[i] AFH reset failed: no HCI verdict (controller down?); the mask may persist until the controller restarts"
    fi
else
    echo "[i] repo copy of scripts/bt-afh-guard not found; sending the reset via hcitool without verification"
    hcitool cmd 0x03 0x003F 0xFF 0xFF 0xFF 0xFF 0xFF 0xFF 0xFF 0xFF 0xFF 0x7F >/dev/null 2>&1 \
        && echo "[ok] AFH host classification sent via hcitool (status unverifiable)"
fi

find /usr/lib -path '*spa-0.2/bluez5/libspa-codec-bluez5-aac.so' -delete -print 2>/dev/null \
    | sed 's/^/[ok] removed /'
echo "[ok] uninstalled. Restart bluetooth (sudo systemctl restart bluetooth) to drop AAC."
