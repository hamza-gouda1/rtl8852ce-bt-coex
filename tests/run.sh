#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Test runner for bt-afh-guard's pure mask logic. Dependency-free: plain bash,
# a stub `iw` on PATH, and real `iw dev <if> info` fixtures in tests/fixtures/.
# Exit status: 0 = all tests passed, 1 = at least one failure.
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
GUARD="$REPO/scripts/bt-afh-guard"
FIXTURES="$HERE/fixtures"

PASS=0 FAIL=0
t()    { echo "== $*"; }
p()    { PASS=$((PASS+1)); }
f()    { echo "FAIL: $*"; FAIL=$((FAIL+1)); }

assert_eq() {   # expected actual label
    if [ "$1" != "$2" ]; then
        f "$3: expected [$1] got [$2]"
    else
        p
    fi
}

# ---------------------------------------------------------------------------
# Source the guard (its main loop is guarded by BASH_SOURCE, so sourcing is safe)
# ---------------------------------------------------------------------------
# shellcheck disable=SC1090
source "$GUARD"

# ---------------------------------------------------------------------------
# Stub `iw`: maps `iw dev` -> <IW_FIXTURE_DIR>/dev.txt and
# `iw dev <if> info` -> <IW_FIXTURE_DIR>/info-<if>.txt so wifi_block can be
# exercised against recorded output instead of live hardware.
# ---------------------------------------------------------------------------
STUBBIN=$(mktemp -d)
trap 'rm -rf "$STUBBIN"' EXIT
cat > "$STUBBIN/iw" <<'EOF'
#!/bin/bash
# Test stub: replays recorded iw output from IW_FIXTURE_DIR.
if [ "${1:-}" = "dev" ] && [ $# -eq 1 ]; then
    cat "$IW_FIXTURE_DIR/dev.txt"
    exit 0
fi
if [ "${1:-}" = "dev" ] && [ "${3:-}" = "info" ]; then
    f="$IW_FIXTURE_DIR/info-$2.txt"
    [ -r "$f" ] || exit 2
    cat "$f"
    exit 0
fi
exit 2
EOF
chmod +x "$STUBBIN/iw"

ORIG_PATH="$PATH"

wifi_block_with_fixture() {   # $1 = fixture case dir; prints wifi_block output with stubbed iw
    (
        export IW_FIXTURE_DIR="$FIXTURES/iw/$1"
        export PATH="$STUBBIN:$PATH"
        wifi_block
    )
}

# ---------------------------------------------------------------------------
t "parse_iw_info: recorded iw output"
# ---------------------------------------------------------------------------
assert_eq "2412 20" "$(parse_iw_info "$(cat "$FIXTURES/iw/ch1-20/info-wlan0.txt")")" "ch1/20 -> center width"
assert_eq "2422 40" "$(parse_iw_info "$(cat "$FIXTURES/iw/ch5-40/info-wlan0.txt")")" "ch5/40 c2422 -> center width"
assert_eq "2437 20" "$(parse_iw_info "$(cat "$FIXTURES/iw/ch6-20/info-wlan0.txt")")" "ch6/20 -> center width"
assert_eq "2437 20" "$(parse_iw_info "$(cat "$FIXTURES/iw/ch6-20-nocenter/info-wlan0.txt")")" "ch6/20 no center1 -> center defaults to control freq"
assert_eq "2452 40" "$(parse_iw_info "$(cat "$FIXTURES/iw/ch11-40/info-wlan0.txt")")" "ch11/40 c2452 -> center width"
assert_eq "2472 20" "$(parse_iw_info "$(cat "$FIXTURES/iw/ch13-20/info-wlan0.txt")")" "ch13/20 -> center width"
assert_eq "2484 20" "$(parse_iw_info "$(cat "$FIXTURES/iw/ch14/info-wlan0.txt")")" "ch14 (no width, no center1) -> 20 MHz default"
assert_eq ""        "$(parse_iw_info "$(cat "$FIXTURES/iw/nolink/info-wlan0.txt")")" "no link -> empty"
assert_eq "5210 80" "$(parse_iw_info "$(cat "$FIXTURES/iw/5ghz/info-wlan0.txt")")" "5 GHz -> center width (wifi_block filters it out)"
assert_eq "5955 20" "$(parse_iw_info "$(cat "$FIXTURES/iw/6ghz/info-wlan0.txt")")" "6 GHz -> center width (wifi_block filters it out)"

# ---------------------------------------------------------------------------
t "wifi_block: recorded iw output via stubbed iw (union over interfaces)"
# ---------------------------------------------------------------------------
assert_eq "2400 2424" "$(wifi_block_with_fixture ch1-20)"        "ch1/20 block"
assert_eq "2400 2444" "$(wifi_block_with_fixture ch5-40)"        "ch5/40 block"
assert_eq "2425 2449" "$(wifi_block_with_fixture ch6-20)"        "ch6/20 block"
assert_eq "2425 2449" "$(wifi_block_with_fixture ch6-20-nocenter)" "ch6/20 without center1 -> control freq as center"
assert_eq "2430 2474" "$(wifi_block_with_fixture ch11-40)"       "ch11/40 block"
assert_eq "2460 2484" "$(wifi_block_with_fixture ch13-20)"       "ch13/20 block"
assert_eq "2472 2496" "$(wifi_block_with_fixture ch14)"          "ch14 block (band edge)"
assert_eq ""          "$(wifi_block_with_fixture 5ghz)"          "5 GHz -> no 2.4 GHz block"
assert_eq ""          "$(wifi_block_with_fixture 6ghz)"          "6 GHz -> no 2.4 GHz block"
assert_eq ""          "$(wifi_block_with_fixture nolink)"        "no link -> no block"
assert_eq "2430 2474" "$(wifi_block_with_fixture two-ifaces)"    "5 GHz + 2.4 GHz interfaces -> only the 2.4 GHz block"

# ---------------------------------------------------------------------------
t "build_mask: exact host classifications (bit 79 always 0)"
# ---------------------------------------------------------------------------
assert_eq "0x00 0x00 0x80 0xFF 0xFF 0xFF 0xFF 0xFF 0xFF 0x7F" "$(build_mask 2400 2424)" "mask ch1/20"
assert_eq "0x00 0x00 0x00 0x00 0x00 0xF8 0xFF 0xFF 0xFF 0x7F" "$(build_mask 2400 2444)" "mask ch5/40"
assert_eq "0xFF 0xFF 0x7F 0x00 0x00 0x00 0xFF 0xFF 0xFF 0x7F" "$(build_mask 2425 2449)" "mask ch6/20"
assert_eq "0xFF 0xFF 0xFF 0x0F 0x00 0x00 0x00 0x00 0x00 0x7E" "$(build_mask 2430 2474)" "mask ch11/40"
assert_eq "0xFF 0xFF 0xFF 0xFF 0xFF 0xFF 0xFF 0x03 0x00 0x00" "$(build_mask 2460 2484)" "mask ch13/20"
assert_eq "0xFF 0xFF 0xFF 0xFF 0xFF 0xFF 0xFF 0xFF 0x3F 0x00" "$(build_mask 2472 2496)" "mask ch14"
assert_eq "$ALL_USABLE" "$(build_mask "" "")" "no Wi-Fi block -> all-usable mask"
assert_eq "$ALL_USABLE" "$(build_mask 2400 2480)" "block leaving <20 usable channels -> refused, all-usable returned"

# ---------------------------------------------------------------------------
t "mask_usable_count"
# ---------------------------------------------------------------------------
assert_eq "56" "$(mask_usable_count "$(build_mask 2400 2424)")" "usable ch1/20"
assert_eq "36" "$(mask_usable_count "$(build_mask 2400 2444)")" "usable ch5/40"
assert_eq "54" "$(mask_usable_count "$(build_mask 2425 2449)")" "usable ch6/20"
assert_eq "34" "$(mask_usable_count "$(build_mask 2430 2474)")" "usable ch11/40 (34 = the v1.0 worked example in SOLUTION.md)"
assert_eq "58" "$(mask_usable_count "$(build_mask 2460 2484)")" "usable ch13/20"
assert_eq "70" "$(mask_usable_count "$(build_mask 2472 2496)")" "usable ch14"
assert_eq "79" "$(mask_usable_count "$ALL_USABLE")" "usable all-usable"

# ---------------------------------------------------------------------------
t "verified sender: hcitool_cc_status parses real hcitool dumps"
# ---------------------------------------------------------------------------
CC_OK='> HCI Event: Command Complete (0x0e) plen 6
      01 3F 0C 00'
CC_REJ='> HCI Event: Command Complete (0x0e) plen 6
      01 3F 0C 12'
CC_READAFH='> HCI Event: Command Complete (0x0e) plen 17
      01 06 14 00 04 00 FF FF FF 00 00 00 00 00 00 60'
assert_eq "0x00" "$(hcitool_cc_status "$CC_OK" 3F 0C)" "cc status ok (Set AFH opcode 0x0C3F)"
assert_eq "0x12" "$(hcitool_cc_status "$CC_REJ" 3F 0C)" "cc status rejected 0x12"
assert_eq "0x00 0x04 0x00 0xFF 0xFF 0xFF 0x00 0x00 0x00 0x00 0x00 0x00 0x60" \
    "$(hcitool_cc_status "$CC_READAFH" 06 14)" "cc status + return params (Read AFH, handle 4)"
assert_eq "NO-CC" "$(hcitool_cc_status "< HCI Command: Set AFH Host Channel Classification (0x03|0x003f) plen 10" 3F 0C)" "no Command Complete -> NO-CC"
assert_eq "OPCODE-MISMATCH" "$(hcitool_cc_status "$CC_OK" 06 14)" "opcode mismatch detection"

# ---------------------------------------------------------------------------
t "verified sender: hci_send via stubbed python backend"
# ---------------------------------------------------------------------------
cat > "$STUBBIN/hci-cmd.py" <<'EOF'
#!/bin/bash
# Test stub for scripts/hci-cmd.py: emits HCISTUB_STATUS + HCISTUB_PARAMS.
printf 'status %s\n' "${HCISTUB_STATUS:-0x00}"
[ -n "${HCISTUB_PARAMS:-}" ] && printf '%s\n' "$HCISTUB_PARAMS"
exit "${HCISTUB_RC:-0}"
EOF
chmod +x "$STUBBIN/hci-cmd.py"
export PATH="$STUBBIN:$PATH"

TMP_OUT="$STUBBIN/out.txt"
HCI_CMD_PY="$STUBBIN/hci-cmd.py"

HCI_STATUS=""
export HCISTUB_STATUS=0x00 HCISTUB_RC=0 HCISTUB_PARAMS=""
hci_send hci0 0x03 0x003F $ALL_USABLE >"$TMP_OUT"
rc=$?
assert_eq "0x00" "$HCI_STATUS" "python backend: status parsed"
assert_eq "" "$(cat "$TMP_OUT")" "python backend: no return params for Set AFH"
assert_eq "0" "$rc" "python backend: returns 0 on accepted command"

HCI_STATUS=""
export HCISTUB_STATUS=0x00 HCISTUB_RC=0 HCISTUB_PARAMS="0x04 0x00 0xFF 0xFF 0xFF 0x00 0x00 0x00 0x00 0x00 0x00 0x60"
hci_send hci0 0x05 0x0006 0x04 0x00 >"$TMP_OUT"
rc=$?
assert_eq "0x00" "$HCI_STATUS" "python backend: read-afh status"
assert_eq "0x04 0x00 0xFF 0xFF 0xFF 0x00 0x00 0x00 0x00 0x00 0x00 0x60" "$(cat "$TMP_OUT")" "python backend: return params forwarded"

HCI_STATUS=""
export HCISTUB_STATUS=0x12 HCISTUB_RC=18
hci_send hci0 0x03 0x003F $ALL_USABLE >"$TMP_OUT"
rc=$?
assert_eq "0x12" "$HCI_STATUS" "python backend: rejected status captured"
assert_eq "1" "$rc" "python backend: rejected -> rc 1"

# ---------------------------------------------------------------------------
t "verified sender: hci_send via stubbed hcitool fallback"
# ---------------------------------------------------------------------------
cat > "$STUBBIN/hcitool" <<'EOF'
#!/bin/bash
# Test stub for hcitool: replays canned Command Complete dumps.
case "${HCITOOL_STUB_CASE:-ok}" in
    ok)      printf '< HCI Command: Set AFH Host Channel Classification (0x03|0x003f) plen 10\n> HCI Event: Command Complete (0x0e) plen 6\n      01 3F 0C 00\n' ;;
    reject)  printf '< HCI Command: Set AFH Host Channel Classification (0x03|0x003f) plen 10\n> HCI Event: Command Complete (0x0e) plen 6\n      01 3F 0C 12\n' ;;
    nocc)    printf '< HCI Command: Set AFH Host Channel Classification (0x03|0x003f) plen 10\n' ;;
    readafh) printf '< HCI Command: Read AFH Channel Map (0x05|0x0006) plen 2\n> HCI Event: Command Complete (0x0e) plen 17\n      01 06 14 00 04 00 FF FF FF 00 00 00 00 00 00 60\n' ;;
esac
EOF
chmod +x "$STUBBIN/hcitool"

TMP_OUT="$STUBBIN/out2.txt"
export HCI_CMD_PY=""

HCI_STATUS=""
HCITOOL_STUB_CASE=ok hci_send hci0 0x03 0x003F $ALL_USABLE >"$TMP_OUT"
rc=$?
assert_eq "0x00" "$HCI_STATUS" "hcitool fallback: status parsed"
assert_eq "" "$(cat "$TMP_OUT")" "hcitool fallback: no return params for Set AFH"
assert_eq "0" "$rc" "hcitool fallback: rc 0 on accept"

HCI_STATUS=""
HCITOOL_STUB_CASE=reject hci_send hci0 0x03 0x003F $ALL_USABLE >"$TMP_OUT"
rc=$?
assert_eq "0x12" "$HCI_STATUS" "hcitool fallback: rejected status captured"
assert_eq "1" "$rc" "hcitool fallback: rejected -> rc 1"

HCI_STATUS=""
HCITOOL_STUB_CASE=readafh hci_send hci0 0x05 0x0006 0x04 0x00 >"$TMP_OUT"
rc=$?
assert_eq "0x00" "$HCI_STATUS" "hcitool fallback: read-afh status"
assert_eq "0x04 0x00 0xFF 0xFF 0xFF 0x00 0x00 0x00 0x00 0x00 0x00 0x60" "$(cat "$TMP_OUT")" "hcitool fallback: return params parsed"

HCI_STATUS=""
HCITOOL_STUB_CASE=nocc hci_send hci0 0x03 0x003F $ALL_USABLE >"$TMP_OUT"
rc=$?
assert_eq "" "$HCI_STATUS" "hcitool fallback: NO-CC leaves HCI_STATUS empty"
assert_eq "1" "$rc" "hcitool fallback: NO-CC -> rc 1"

# restore PATH polluted by the stub-backed tests
PATH="$ORIG_PATH"

# ---------------------------------------------------------------------------
t "invariants (bit 79 reserved = 0, at least 20 usable channels)"
# ---------------------------------------------------------------------------
for m in "$(build_mask 2400 2424)" "$(build_mask 2400 2444)" "$(build_mask 2425 2449)" \
         "$(build_mask 2430 2474)" "$(build_mask 2460 2484)" "$(build_mask 2472 2496)" "$ALL_USABLE"; do
    last_byte=${m##* }
    if [ $(( last_byte )) -ge 128 ]; then
        f "bit 79 must be 0: mask [$m]"
    else
        p
    fi
    u=$(mask_usable_count "$m")
    if [ "$u" -lt 20 ]; then
        f "every sent mask needs >=20 usable channels: [$m] has $u"
    else
        p
    fi
done

echo
echo "passed: $PASS, failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
