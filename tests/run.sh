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
# Real hcitool output, recorded on the reference laptop (tests/fixtures/hci/),
# plus rejected and Command Status cases in the same format.
HCIFIX="$FIXTURES/hci"
CC_OK='< HCI Command: ogf 0x03, ocf 0x003f, plen 10
  FF FF FF FF FF FF FF FF FF 7F
> HCI Event: 0x0e plen 4
  01 3F 0C 00 '
CC_REJ='< HCI Command: ogf 0x03, ocf 0x003f, plen 10
  FF FF FF FF FF FF FF FF FF FF
> HCI Event: 0x0e plen 4
  01 3F 0C 12 '
CS_REJ='< HCI Command: ogf 0x03, ocf 0x003f, plen 10
  FF FF FF FF FF FF FF FF FF 7F
> HCI Event: 0x0f plen 4
  0C 01 3F 0C '
CC_READAFH=$(cat "$HCIFIX/hcitool-read-afh-map.txt")
CC_VERSION=$(cat "$HCIFIX/hcitool-read-local-version.txt")
assert_eq "0x00" "$(hcitool_cc_status "$CC_OK" 3F 0C)" "cc status ok (Set AFH opcode 0x0C3F)"
assert_eq "0x12" "$(hcitool_cc_status "$CC_REJ" 3F 0C)" "cc status rejected 0x12"
assert_eq "0x0C" "$(hcitool_cc_status "$CS_REJ" 3F 0C)" "Command Status rejection 0x0C (Command Disallowed)"
assert_eq "0x00 0x04 0x00 0x01 0x00 0x00 0x00 0xF8 0xFF 0xFF 0xFF 0xFF 0xFF 0x7F" \
    "$(hcitool_cc_status "$CC_READAFH" 06 14)" "recorded Read AFH Channel Map: status + handle + mode + map"
assert_eq "0x00 0x0C 0x0D 0x04 0x0C 0x5D 0x00 0x25 0x72" \
    "$(hcitool_cc_status "$CC_VERSION" 01 10)" "recorded Read Local Version Information"
assert_eq "NO-CC" "$(hcitool_cc_status "< HCI Command: ogf 0x03, ocf 0x003f, plen 10" 3F 0C)" "no event -> NO-CC"
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
export HCISTUB_STATUS=0x00 HCISTUB_RC=0 HCISTUB_PARAMS="0x04 0x00 0x01 0xFF 0xFF 0xFF 0x00 0x00 0x00 0x00 0x00 0x00 0x60"
hci_send hci0 0x05 0x0006 0x04 0x00 >"$TMP_OUT"
rc=$?
assert_eq "0x00" "$HCI_STATUS" "python backend: read-afh status"
assert_eq "0x04 0x00 0x01 0xFF 0xFF 0xFF 0x00 0x00 0x00 0x00 0x00 0x00 0x60" "$(cat "$TMP_OUT")" "python backend: return params forwarded"

HCI_STATUS=""
export HCISTUB_STATUS=0x12 HCISTUB_RC=18
hci_send hci0 0x03 0x003F $ALL_USABLE >"$TMP_OUT"
rc=$?
assert_eq "0x12" "$HCI_STATUS" "python backend: rejected status captured"
assert_eq "1" "$rc" "python backend: rejected -> rc 1"

# ---------------------------------------------------------------------------
t "verified sender: hci_send via stubbed hcitool fallback"
# ---------------------------------------------------------------------------
cat > "$STUBBIN/hcitool" <<'STUB'
#!/bin/bash
# Test stub for hcitool: replays recorded output (and same-format reject cases).
if [ "${1:-}" = "con" ]; then
    cat "$HCIFIX/hcitool-con.txt"
    exit 0
fi
case "${HCITOOL_STUB_CASE:-ok}" in
    ok)      printf '%s\n' "$CC_OK" ;;
    reject)  printf '%s\n' "$CC_REJ" ;;
    nocc)    printf '< HCI Command: ogf 0x03, ocf 0x003f, plen 10\n' ;;
    readafh) cat "$HCIFIX/hcitool-read-afh-map.txt" ;;
esac
STUB
chmod +x "$STUBBIN/hcitool"

TMP_OUT="$STUBBIN/out2.txt"
export HCI_CMD_PY="" HCIFIX CC_OK CC_REJ

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
assert_eq "0x04 0x00 0x01 0x00 0x00 0x00 0xF8 0xFF 0xFF 0xFF 0xFF 0xFF 0x7F" "$(cat "$TMP_OUT")" "hcitool fallback: recorded return params parsed"

HCI_STATUS=""
HCITOOL_STUB_CASE=nocc hci_send hci0 0x03 0x003F $ALL_USABLE >"$TMP_OUT"
rc=$?
assert_eq "" "$HCI_STATUS" "hcitool fallback: NO-CC leaves HCI_STATUS empty"
assert_eq "1" "$rc" "hcitool fallback: NO-CC -> rc 1"

# ---------------------------------------------------------------------------
t "live-map readback: handle enumeration, map extraction, overlap count"
# ---------------------------------------------------------------------------
export PATH="$STUBBIN:$PATH"   # stub hcitool: `hcitool con` -> one ACL handle 4
assert_eq "4" "$(list_acl_handles)" "list_acl_handles: hcitool con -> ACL handle 4"

export HCISTUB_STATUS=0x00 HCISTUB_RC=0 HCISTUB_PARAMS="0x04 0x00 0x01 0xFF 0xFF 0xFF 0x00 0x00 0x00 0x00 0x00 0x00 0x60"
export HCI_CMD_PY="$STUBBIN/hci-cmd.py"
m=$(read_live_map 4)
assert_eq "0xFF 0xFF 0xFF 0x00 0x00 0x00 0x00 0x00 0x00 0x60" "$m" "read_live_map: skips handle (2) + AFH_Mode (1)"
HCI_CMD_PY=""
m=$(HCITOOL_STUB_CASE=readafh read_live_map 4)
assert_eq "0x00 0x00 0x00 0xF8 0xFF 0xFF 0xFF 0xFF 0xFF 0x7F" "$m" "read_live_map: recorded hcitool dump"
assert_eq "0" "$(overlap_count "$m" 2400 2424)" "recorded live map vs the recorded ch1/20 block: 0 overlap"
export HCI_CMD_PY="$STUBBIN/hci-cmd.py"

# the measured v1.0 live map (channels 0-23 and 77-78) vs the ch11/40 block
LIVE="0xFF 0xFF 0xFF 0x00 0x00 0x00 0x00 0x00 0x00 0x60"
assert_eq "0" "$(overlap_count "$LIVE" 2430 2474)" "overlap: measured v1.0 live map vs ch11/40 block = 0"
assert_eq "23" "$(overlap_count "$LIVE" 2400 2424)" "overlap: same map vs ch1/20 block = 23 live channels inside"
assert_eq "1" "$(overlap_count "0xFF 0xFF 0xFF 0x40 0x00 0x00 0x00 0x00 0x00 0x60" 2430 2474)" "overlap: ch30 set -> 1"

# ---------------------------------------------------------------------------
t "hold-down state machine (guard_decide)"
# ---------------------------------------------------------------------------
M1140=$(build_mask 2430 2474)   # ch11/40
M120=$(build_mask 2400 2424)    # ch1/20

# fresh state
last=""; last_sent=0; hold_start=0; hold_block=""; force=0
assert_eq "send $M1140" "$(guard_decide 2430 2474 100)" "fresh guard + 2.4 GHz link: send"
last="$M1140"; last_sent=100
assert_eq "none" "$(guard_decide 2430 2474 105)" "stable link, nothing due: none"
assert_eq "hold" "$(guard_decide "" "" 110)" "link lost: enter hold-down"
hold_start=110; hold_block="$M1140"
assert_eq "hold_wait" "$(guard_decide "" "" 115)" "within hold-down: keep waiting"
assert_eq "resume" "$(guard_decide 2430 2474 130)" "same block returns inside the window: resume"
hold_start=0
assert_eq "hold" "$(guard_decide "" "" 135)" "link lost again: hold anew"
hold_start=135; hold_block="$M1140"
assert_eq "clear $ALL_USABLE" "$(guard_decide "" "" 200)" "hold expired: clear to all-usable"
export last="$ALL_USABLE" last_sent=200 hold_start=0
assert_eq "none" "$(guard_decide "" "" 210)" "already all-usable: none"
assert_eq "refresh $ALL_USABLE" "$(guard_decide "" "" 265)" "all-usable state: periodic refresh due"
assert_eq "send $M120" "$(guard_decide 2400 2424 270)" "link returns after clear: send the new block"

# channel change DURING a hold-down: the new block takes precedence
export last="$M1140" hold_start=110 hold_block="$M1140"
assert_eq "send $M120" "$(guard_decide 2400 2424 130)" "channel changed during hold-down: send new block"

# force (controller just came back) overrides "none"
export last="$M1140" hold_start=0 force=1
assert_eq "send $M1140" "$(guard_decide 2430 2474 105)" "force after controller return: send"

# HOLD_S=0 disables the hold-down (v1.0 behaviour): hold then immediate clear
export last="$M1140" hold_start=0
HOLD_S=0
assert_eq "hold" "$(guard_decide "" "" 300)" "HOLD_S=0: hold entered"
export hold_start=300
assert_eq "clear $ALL_USABLE" "$(guard_decide "" "" 300)" "HOLD_S=0: clear at the same instant"
export HOLD_S=30

# ---------------------------------------------------------------------------
t "config validation falls back to defaults on garbage"
# ---------------------------------------------------------------------------
export GUARD_MHZ=999 INTERVAL=abc REFRESH=-5 HOLD_S=9999 HCI=hciX
validate_config
assert_eq "2" "$GUARD_MHZ" "GUARD_MHZ out of range -> default"
assert_eq "5" "$INTERVAL" "non-numeric INTERVAL -> default"
assert_eq "60" "$REFRESH" "negative REFRESH -> default"
assert_eq "30" "$HOLD_S" "huge HOLD_S -> default"
assert_eq "hci0" "$HCI" "bad HCI name -> default"
export GUARD_MHZ=3 INTERVAL=10 REFRESH=300 HOLD_S=0 HCI=hci1
validate_config
assert_eq "3" "$GUARD_MHZ" "valid custom values survive validation"

# ---------------------------------------------------------------------------
t "version and help"
# ---------------------------------------------------------------------------
assert_eq "bt-afh-guard $GUARD_VERSION" "$(bash "$REPO/scripts/bt-afh-guard" --version)" "--version output"
help_count=$(bash "$REPO/scripts/bt-afh-guard" --help 2>&1 | grep -c 'Usage:')
assert_eq "1" "$help_count" "--help prints usage"

# ---------------------------------------------------------------------------
t "analyze-stalls.sh: canned decoded-btmon trace"
# ---------------------------------------------------------------------------
TESTCAP=$(mktemp -d)
trap 'rm -rf "$STUBBIN" "$TESTCAP"' EXIT
cat > "$TESTCAP/hci.txt" <<'EOF'
@ ACL Data TX: handle 4 plen 27                         [hci0] 10.00.00.000000
@ ACL Data TX: handle 4 plen 27                         [hci0] 10.00.00.010000
@ ACL Data TX: handle 4 plen 27                         [hci0] 10.00.00.200000
@ ACL Data TX: handle 4 plen 27                         [hci0] 10.00.00.210000
@ ACL Data TX: handle 20 plen 27                        [hci0] 10.00.00.900000
EOF
out=$(bash "$REPO/scripts/analyze-stalls.sh" "$TESTCAP")
assert_eq "1" "$(echo "$out" | grep -c 'handle 4:')" "busiest handle auto-detects to 4 (not 20)"
assert_eq "1" "$(echo "$out" | grep -c 'stalls > 50 ms: 1 ')" "one stall detected (the 190 ms gap)"
assert_eq "1" "$(echo "$out" | grep -c 'p95 190.0 ms')" "p95 gap"
assert_eq "1" "$(echo "$out" | grep -c 'worst 190.0 ms')" "worst gap"

cat > "$TESTCAP/one.txt" <<'EOF'
@ ACL Data TX: handle 4 plen 27   [hci0] 10.00.00.000000
@ ACL Data TX: handle 4 plen 27   [hci0] 10.00.00.010000
EOF
out=$(bash "$REPO/scripts/analyze-stalls.sh" "$TESTCAP/one.txt" 4)
assert_eq "1" "$(echo "$out" | grep -c 'stalls > 50 ms: 0')" "zero-stall case"

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

# ---------------------------------------------------------------------------
t "hci-cmd.py: packet parser and kernel struct layouts (python unittest)"
# ---------------------------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
    if py_out=$(python3 -m unittest discover -s "$HERE" -p 'test_*.py' 2>&1); then
        p
    else
        f "python unittest suite"
    fi
    tail -3 <<<"$py_out"
else
    echo "(python3 not found -- skipped)"
fi

echo
echo "passed: $PASS, failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
