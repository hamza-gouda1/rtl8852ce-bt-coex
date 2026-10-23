#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Remove the bt-afh-guard service and the AAC plugin, and restore the
# controller's default (all channels usable) host classification.
# Part of rtl8852ce-bt-coex by Hamza Gouda (GPL-2.0)
# Usage: sudo bash scripts/uninstall.sh
set -u
[ "$EUID" -eq 0 ] || { echo "Run with sudo"; exit 1; }
systemctl disable --now bt-afh-guard.service 2>/dev/null
rm -f /etc/systemd/system/bt-afh-guard.service /usr/local/sbin/bt-afh-guard
systemctl daemon-reload
hcitool cmd 0x03 0x003F 0xFF 0xFF 0xFF 0xFF 0xFF 0xFF 0xFF 0xFF 0xFF 0x7F >/dev/null 2>&1 \
    && echo "[ok] AFH host classification reset (all channels usable)"
find /usr/lib -path '*spa-0.2/bluez5/libspa-codec-bluez5-aac.so' -delete -print 2>/dev/null \
    | sed 's/^/[ok] removed /'
echo "[ok] uninstalled. Restart bluetooth (sudo systemctl restart bluetooth) to drop AAC."
