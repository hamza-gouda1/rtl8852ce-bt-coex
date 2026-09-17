#!/usr/bin/env bash
# Swaps the in-tree rtw89 modules for our debugfs-enabled build (v3).
# State detection is based on the module dir contents:
#   rtw89_core.ko      -> our build installed
#   rtw89_core.ko.zst  -> stock modules in place
# Safety: originals kept in <script dir>/orig-backup/; any failure writes
# swap-failure.log and rolls back automatically.
# Cost: ~10 s WiFi interruption. Bluetooth untouched.
set -u
KVER=$(uname -r)
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MODDIR="/lib/modules/$KVER/kernel/drivers/net/wireless/realtek/rtw89"
BACKUP="$SCRIPT_DIR/orig-backup"
SRC="$SCRIPT_DIR/rtw89-src"
FAILLOG="$SCRIPT_DIR/swap-failure.log"
MODS="rtw89_core rtw89_pci rtw89_8852c rtw89_8852ce"

ok() { echo "[OK] $*"; }
fail() { echo "[FAIL] $*"; }

diag() {
    echo "=== swap diagnostics $(date) ===" > "$FAILLOG"
    echo "--- lsmod rtw89:" >> "$FAILLOG" ; lsmod | grep rtw89 >> "$FAILLOG" 2>&1
    echo "--- modinfo -n:" >> "$FAILLOG"
    for m in $MODS; do modinfo -n "$m" >> "$FAILLOG" 2>&1; done
    echo "--- /sys/kernel/debug top level:" >> "$FAILLOG"
    ls -la /sys/kernel/debug/ >> "$FAILLOG" 2>&1
    echo "--- kernel log tail:" >> "$FAILLOG"
    dmesg | grep -iE 'rtw89|debugfs|wlan' | tail -80 >> "$FAILLOG" 2>&1
    echo "--- driver binding:" >> "$FAILLOG"
    readlink -f /sys/class/net/wlp108s0/device/driver >> "$FAILLOG" 2>&1
    ls /sys/module/ | grep -E 'rtw89|mac80211' >> "$FAILLOG" 2>&1
    echo "[*] diagnostics written to $FAILLOG"
}

verify_iface() {
    ip link show wlp108s0 >/dev/null 2>&1
}

find_debugfs() {
    find /sys/kernel/debug -maxdepth 1 -mindepth 1 -type d \
         \( -name 'rtw89' -o -name '*6c:00*' \) 2>/dev/null | head -1
}

rollback() {
    echo "[*] ROLLING BACK to original modules ..."
    for m in $MODS; do
        rm -f "$MODDIR/$m.ko"
        [ -f "$BACKUP/$m.ko.zst" ] && cp "$BACKUP/$m.ko.zst" "$MODDIR/$m.ko.zst"
    done
    depmod -a "$KVER"
    modprobe -r rtw89_8852ce 2>/dev/null
    modprobe rtw89_8852ce
    sleep 5
    if verify_iface; then
        ok "original driver restored, WiFi is back"
    else
        fail "original driver also failed -- plug Ethernet, then: sudo depmod -a $KVER && sudo modprobe rtw89_8852ce (or reboot)"
    fi
}

[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
[ -f "$SRC/rtw89_core.ko" ] || { echo "built modules missing in $SRC"; exit 1; }
mkdir -p "$BACKUP"

OUR_INSTALLED=false
[ -f "$MODDIR/rtw89_core.ko" ] && OUR_INSTALLED=true
ORIG_PRESENT=false
[ -f "$MODDIR/rtw89_core.ko.zst" ] && ORIG_PRESENT=true

if $OUR_INSTALLED; then
    echo "[*] Our build is already installed -- reloading modules."
elif $ORIG_PRESENT; then
    echo "[*] Stock modules in place -- installing our build ..."
    for m in $MODS; do
        [ -f "$MODDIR/$m.ko.zst" ] || { echo "unexpected: $m.ko.zst missing"; exit 1; }
    done
    for m in $MODS; do
        mv "$MODDIR/$m.ko.zst" "$BACKUP/" || { echo "move failed, nothing changed"; exit 1; }
    done
    for m in $MODS; do
        cp "$SRC/$m.ko" "$MODDIR/$m.ko" || { diag; rollback; exit 1; }
    done
    depmod -a "$KVER" || { diag; rollback; exit 1; }
else
    echo "No rtw89 modules in $MODDIR -- restoring from backup ..."
    for m in $MODS; do
        [ -f "$BACKUP/$m.ko.zst" ] && cp "$BACKUP/$m.ko.zst" "$MODDIR/$m.ko.zst"
    done
    depmod -a "$KVER"
    ORIG_PRESENT=true
fi

echo "[*] Unloading current driver (all four modules) ..."
modprobe -r rtw89_8852ce rtw89_8852c rtw89_pci rtw89_core 2>/dev/null
for i in $(seq 1 10); do
    LEFT=""
    for m in $MODS; do lsmod | grep -q "^$m " && LEFT="$LEFT $m"; done
    [ -z "$LEFT" ] && break
    modprobe -r $LEFT 2>/dev/null
    sleep 1
done
LEFT=""
for m in $MODS; do lsmod | grep -q "^$m " && LEFT="$LEFT $m"; done
if [ -n "$LEFT" ]; then
    echo "[FAIL] modules refused to unload:$LEFT -- current holders:"
    lsmod | grep -E 'rtw89|mac80211|cfg80211' | sed 's/^/    /'
    diag
    rollback
    exit 1
fi
echo "[OK] all rtw89 modules unloaded"

echo "[*] Loading rtw89 build ..."
modprobe rtw89_8852ce || { diag; rollback; exit 1; }

echo "[*] LOADED-MODULE IDENTITIES (version otree-dbg = our build):"
echo "    rtw89_8852ce: $(cat /sys/module/rtw89_8852ce/version 2>/dev/null || echo 'NO VERSION SYSFS')"
echo "    rtw89_core:   $(cat /sys/module/rtw89_core/version 2>/dev/null || echo 'NO VERSION SYSFS')"
grep -E '^rtw89' /proc/modules | sed 's/^/    /'
echo "[*] dep index entry:"
grep 'rtw8852ce' "/lib/modules/$KVER/modules.dep" | head -2 | sed 's/^/    /'

echo "[*] Probe markers right after load:"
dmesg | grep -E 'OUT-OF-TREE|debugfs_init|loaded firmware' | tail -6

RESOLVED=$(modinfo -n rtw89_core)
echo "[*] depmod resolves rtw89_core to: $RESOLVED"
case "$RESOLVED" in
    *.ko)   ok "our build is what the kernel will use" ;;
    *.ko.zst) fail "depmod resolves to the STOCK module -- install step went wrong"
             diag; rollback; exit 1 ;;
esac

for i in $(seq 1 20); do
    if verify_iface; then
        ok "wlp108s0 is up"
        break
    fi
    [ "$i" -eq 20 ] && { diag; rollback; fail "interface never came up"; exit 1; }
    sleep 1
done

DBG=$(find_debugfs)
if [ -n "$DBG" ]; then
    ok "debugfs tree found at: $DBG"
    ls -la "$DBG"
    echo "[*] SUCCESS -- our driver with coex instrumentation is running."
    echo "[*] NetworkManager is reconnecting; connect your audio device now."
    exit 0
else
    fail "driver is up but the debugfs tree is missing -- our instrumentation did not appear"
    diag
    rollback
    exit 1
fi
