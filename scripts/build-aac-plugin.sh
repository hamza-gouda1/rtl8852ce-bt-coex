#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Build PipeWire's Bluetooth AAC codec plugin (libspa-codec-bluez5-aac.so) for the
# EXACT PipeWire version installed on this machine.
# Part of rtl8852ce-bt-coex by Hamza Gouda (GPL-2.0)
#
# Why: Debian/Ubuntu ship PipeWire without AAC (libfdk-aac is non-free), so
# AAC-capable earbuds fall back to SBC / SBC-XQ. AAC sounds as good or better
# while using roughly half the airtime of SBC-XQ, which matters a lot on a
# combo card where Bluetooth shares the 2.4 GHz radio with Wi-Fi.
#
# Runs as your normal user (no root). Install the result with scripts/install.sh.
# Build deps (once):
#   sudo apt install build-essential meson ninja-build pkg-config libfdk-aac-dev \
#        libdbus-1-dev libsbc-dev libbluetooth-dev libglib2.0-dev libudev-dev
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK="$REPO/build-aac"
VER=$(pipewire --version | grep -oP 'libpipewire \K[0-9.]+' | head -1)
[ -n "$VER" ] || { echo "[FAIL] could not read PipeWire version"; exit 1; }
echo "[*] Installed PipeWire: $VER"

for p in meson ninja pkg-config; do command -v $p >/dev/null || { echo "[FAIL] missing $p (see build deps above)"; exit 1; }; done
pkg-config --exists fdk-aac || { echo "[FAIL] libfdk-aac-dev not installed (see build deps above)"; exit 1; }

mkdir -p "$WORK/src"
TARBALL="$WORK/src/pipewire-$VER.tar.gz"
if [ ! -s "$TARBALL" ]; then
    echo "[*] Downloading official PipeWire $VER source ..."
    curl -fL --retry 3 -o "$TARBALL" \
        "https://gitlab.freedesktop.org/pipewire/pipewire/-/archive/$VER/pipewire-$VER.tar.gz"
fi
gzip -t "$TARBALL"
[ -d "$WORK/src/pipewire-$VER" ] || tar -xzf "$TARBALL" -C "$WORK/src"

echo "[*] Configuring a minimal build (only the bluez5 SPA plugin + AAC) ..."
rm -rf "$WORK/build"
meson setup "$WORK/build" "$WORK/src/pipewire-$VER" \
    -Dauto_features=disabled -Dspa-plugins=enabled -Dbluez5=enabled \
    -Dbluez5-codec-aac=enabled -Dsession-managers=[] \
    -Dtests=disabled -Dexamples=disabled -Ddocs=disabled -Dman=disabled >/dev/null

echo "[*] Building libspa-codec-bluez5-aac.so ..."
ninja -C "$WORK/build" spa/plugins/bluez5/libspa-codec-bluez5-aac.so
cp "$WORK/build/spa/plugins/bluez5/libspa-codec-bluez5-aac.so" "$WORK/"
strip --strip-unneeded "$WORK/libspa-codec-bluez5-aac.so"
echo "$VER" > "$WORK/PIPEWIRE_VERSION"

echo "[*] Sanity checks:"
ldd "$WORK/libspa-codec-bluez5-aac.so" | grep -q fdk-aac && echo "    links libfdk-aac: ok"
nm -D --defined-only "$WORK/libspa-codec-bluez5-aac.so" | grep -q spa_handle_factory_enum && echo "    SPA factory export: ok"
echo "[ok] Built: $WORK/libspa-codec-bluez5-aac.so (for PipeWire $VER)"
echo "     Next: sudo bash scripts/install.sh"
