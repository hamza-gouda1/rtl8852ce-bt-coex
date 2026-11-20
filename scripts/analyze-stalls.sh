#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# analyze-stalls.sh — turn a capture-10min.sh run into the stall count that
# goes next to the 488-stall v0.1 baseline in docs/MEASUREMENTS.md.
#
# Reads the decoded btmon text (hci.txt) from a capture directory and counts
# the delivery gaps of the Bluetooth audio link: stall = gap > 50 ms between
# consecutive "ACL Data TX" packets on one handle, the same metric and
# threshold as the v0.1 baseline. Prints one Markdown-ready line.
#
# Usage: bash scripts/analyze-stalls.sh <capture-dir|hci.txt> [HANDLE]
#   Without HANDLE the busiest ACL TX handle is used (that is the A2DP link).
#   No root needed; if hci.txt is missing but hci.btmon is readable (the
#   capture chowns it back to the invoking user), it is decoded first.
#   Assumes the capture does not cross midnight (btmon timestamps are
#   time-of-day); gaps across midnight are skipped, not counted.
set -u

SRC=${1:?usage: analyze-stalls.sh <capture-dir|hci.txt> [HANDLE]}
GAP_S=0.05

if [ -d "$SRC" ]; then
    TXT="$SRC/hci.txt"
    if [ ! -r "$TXT" ] && [ -r "$SRC/hci.btmon" ]; then
        echo "[*] decoding $SRC/hci.btmon with btmon -r ..."
        btmon -r "$SRC/hci.btmon" > "$SRC/hci.txt" 2>/dev/null \
            || { echo "[FAIL] btmon -r could not decode the trace" >&2; exit 1; }
    fi
else
    TXT=$SRC
fi
[ -r "$TXT" ] || { echo "[FAIL] no readable hci.txt for $SRC" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if head -1 "$TXT" 2>/dev/null | grep -q '^# hci-acl-tx v1'; then
    # Native format of scripts/hci-acl-capture.py: "<seconds> <handle> <dlen>".
    HANDLE=${2:-$(tail -n +2 "$TXT" | awk '
        { c[$2]++ }
        END { best = ""; for (k in c) if (c[k] > m) { m = c[k]; best = k }
              print best }')}
    [ -n "$HANDLE" ] || { echo "[FAIL] no ACL TX records in $TXT" >&2; exit 1; }
    awk -v h="$HANDLE" '$2 == h { print $1 }' "$TXT" > "$TMP/sec.txt"
else
    # Busiest ACL TX handle = the audio link (override by passing HANDLE).
    HANDLE=${2:-$(awk '
        $0 ~ /[Aa][Cc][Ll] [Dd]ata TX/ {
            for (i = 1; i <= NF; i++)
                if ($i ~ /^handle:?$/) { cnt[$(i + 1)]++; break }
        }
        END { best = ""; for (k in cnt) if (cnt[k] > max) { max = cnt[k]; best = k }
              print best }' "$TXT")}
    [ -n "$HANDLE" ] || { echo "[FAIL] no ACL Data TX traffic found in $TXT" >&2; exit 1; }

    # Timestamps (seconds of day) of every outgoing ACL packet on that handle.
    awk -v h="$HANDLE" '
        $0 ~ /[Aa][Cc][Ll] [Dd]ata TX/ && $0 ~ ("handle " h "([^0-9]|$)") {
            ts = ""
            for (i = NF; i >= 1; i--)
                if ($i ~ /^[0-9][0-9][:.][0-9][0-9][:.][0-9][0-9]\.[0-9][0-9][0-9][0-9][0-9][0-9]$/) { ts = $i; break }
            if (ts != "") {
                split(ts, t, /[:.]/)
                printf "%.6f\n", t[1] * 3600 + t[2] * 60 + t[3] + t[4] / 1000000
            }
        }' "$TXT" > "$TMP/sec.txt"
fi

TXN=$(wc -l < "$TMP/sec.txt")
[ "$TXN" -gt 1 ] || { echo "[FAIL] only $TXN ACL TX packet(s) for handle $HANDLE in $TXT" >&2; exit 1; }

# Gaps > 50 ms between consecutive packets (the stalls).
awk -v g="$GAP_S" '
    NR == 1 { prev = $1; next }
    { d = $1 - prev; prev = $1; if (d > g) print d }' "$TMP/sec.txt" > "$TMP/gaps.txt"

NGAPS=$(wc -l < "$TMP/gaps.txt")
if [ "$NGAPS" -eq 0 ]; then
    echo "handle $HANDLE: TX ACL packets $TXN | stalls > 50 ms: 0 | accumulated starvation: 0.0 s | p95 - | worst -"
    exit 0
fi
SUM=$(awk '{s += $1} END { printf "%.1f", s }' "$TMP/gaps.txt")
P95=$(sort -n "$TMP/gaps.txt" | awk -v n="$NGAPS" 'NR == int(n * 0.95 + 0.999999) { printf "%.1f", $1 * 1000; exit }')
MAX=$(sort -n "$TMP/gaps.txt" | tail -1 | awk '{ printf "%.1f", $1 * 1000 }')

echo "handle $HANDLE: TX ACL packets $TXN | stalls > 50 ms: $NGAPS | accumulated starvation: $SUM s | p95 ${P95} ms | worst ${MAX} ms"
