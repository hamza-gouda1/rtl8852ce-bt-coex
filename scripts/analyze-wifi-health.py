#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""analyze-wifi-health.py — compare Wi-Fi health while A2DP is RUNNING vs SUSPENDED.

Reads a CSV written by wifi-health-capture.sh. The station-dump counters in
the CSV are cumulative, so they are converted to per-sample deltas (counter
resets, e.g. after a roam or disconnect, clamp to 0). Rows are grouped by the
a2dp column and compared as a Markdown table with sample counts. stdlib only.
"""

import csv
import statistics
import sys

COUNTERS = ("tx_retries", "tx_failed", "beacon_loss", "rx_drop_misc")


def _num(s):
    try:
        return int(s) if s not in (None, "") else 0
    except ValueError:
        return 0


def _float(s):
    try:
        return float(s) if s not in (None, "") else None
    except ValueError:
        return None


def load(path):
    rows = []
    with open(path, newline="") as fh:
        for row in csv.DictReader(fh):
            rows.append(row)
    if not rows:
        print(f"error: {path} has no data rows", file=sys.stderr)
        sys.exit(2)
    return rows


def per_sample_deltas(rows):
    """Cumulative counters -> per-sample deltas; negative deltas (resets) clamp to 0."""
    out = []
    prev = {}
    for r in rows:
        d = {
            "a2dp": r.get("a2dp") or "UNKNOWN",
            "signal": _float(r.get("signal_dbm")),
            "tx_kbits": _float(r.get("tx_kbits")),
            "rx_kbits": _float(r.get("rx_kbits")),
            "event": (r.get("wifi_event") or "").strip(";"),
        }
        for k in COUNTERS:
            cur = _num(r.get(k))
            d[k] = 0 if not prev or cur < prev.get(k, 0) else cur - prev.get(k, 0)
        out.append(d)
        prev = {k: _num(r.get(k)) for k in COUNTERS}
    return out


def main():
    if len(sys.argv) != 2:
        print("usage: analyze-wifi-health.py <capture.csv>", file=sys.stderr)
        return 2

    rows = per_sample_deltas(load(sys.argv[1]))
    groups = {"RUNNING": [], "SUSPENDED": []}
    for d in rows:
        if d["a2dp"] in groups:
            groups[d["a2dp"]].append(d)

    def duration(g):
        return len(g) * 2   # samples at a fixed 2 s cadence

    def rate(g, k):
        dur = max(1, duration(g))
        return sum(d[k] for d in g) / dur

    def median(g, k):
        vals = [d[k] for d in g if d[k] is not None]
        return statistics.median(vals) if vals else float("nan")

    def ev_count(g, name):
        return sum(1 for d in g if name in d["event"])

    unknown = len(rows) - len(groups["RUNNING"]) - len(groups["SUSPENDED"])

    print("## Wi-Fi health: A2DP RUNNING vs SUSPENDED")
    print()
    print("| Metric | A2DP RUNNING | A2DP SUSPENDED |")
    print("|---|---:|---:|")
    print(f"| Samples (2 s each) | {len(groups['RUNNING'])} | {len(groups['SUSPENDED'])} |")
    print(f"| Duration | {duration(groups['RUNNING'])} s | {duration(groups['SUSPENDED'])} s |")
    print(f"| Beacon loss / s | {rate(groups['RUNNING'], 'beacon_loss'):.2f} | {rate(groups['SUSPENDED'], 'beacon_loss'):.2f} |")
    print(f"| TX retries / s | {rate(groups['RUNNING'], 'tx_retries'):.2f} | {rate(groups['SUSPENDED'], 'tx_retries'):.2f} |")
    print(f"| TX failed / s | {rate(groups['RUNNING'], 'tx_failed'):.2f} | {rate(groups['SUSPENDED'], 'tx_failed'):.2f} |")
    print(f"| RX drop misc / s | {rate(groups['RUNNING'], 'rx_drop_misc'):.2f} | {rate(groups['SUSPENDED'], 'rx_drop_misc'):.2f} |")
    print(f"| Disconnects (journal events) | {ev_count(groups['RUNNING'], 'DISCONNECTED')} | {ev_count(groups['SUSPENDED'], 'DISCONNECTED')} |")
    print(f"| Beacon-loss journal events | {ev_count(groups['RUNNING'], 'BEACON-LOSS')} | {ev_count(groups['SUSPENDED'], 'BEACON-LOSS')} |")
    print(f"| Median TX bitrate | {median(groups['RUNNING'], 'tx_kbits'):.0f} kbit/s | {median(groups['SUSPENDED'], 'tx_kbits'):.0f} kbit/s |")
    print(f"| Median RX bitrate | {median(groups['RUNNING'], 'rx_kbits'):.0f} kbit/s | {median(groups['SUSPENDED'], 'rx_kbits'):.0f} kbit/s |")
    if unknown:
        print()
        print(f"({unknown} samples skipped: a2dp state UNKNOWN — run the capture as the desktop user, not under sudo)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
