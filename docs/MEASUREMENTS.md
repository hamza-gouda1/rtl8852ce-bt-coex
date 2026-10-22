# Measurements

All measurements from a single ASUS TUF Gaming F16 (FX608JHR, Foxconn
RTL8852CE), Ubuntu 24.04, liquorix 7.0.13, soundcore P40i BT speaker (A2DP,
SBC-XQ ~456 kbps), 2.4 GHz-only networks. Stall = ACL delivery gap > 50 ms.

## Environment facts (btc_info telemetry, 121 samples / 10 min)

| Field | Value |
|---|---|
| Coex driver version | 9.0.0 |
| Wi-Fi FW coex | 7.12.0 (Match) |
| BT FW coex | **0 (Mismatch, desired 7)** — 121/121 samples |
| AFH map | **empty** — 121/121 samples |
| fcxbtcrpt / fcxtdma | 4/4 ✓, 4/3 (fw4 vs drv3 mismatch) |
| fcxslots/fcxcysta/fcxstep/fcxbtafh/... | **0** (unsupported by Wi-Fi FW) |
| A2DP mailbox | NACKs 2,565 → 41,154 over capture (~50% of tx) |
| Active TDMA policy | `AUTO_TD20B1` (policy_type 1282, W1:B1 = 20:200 ms) |

## Phase-1 baseline (600 s, Wi-Fi idle-ish, 37,149 ACL frames)

| Metric | Value |
|---|---|
| Stalls > 50 ms | 488 |
| Accumulated starvation | 74.0 s (12.3% of wall time) |
| Worst gap | 541.9 ms |
| HCI anomalies (disconnects/mode changes) | 0 |

## Coex policy A/B (5 × 50 s, `btc_policy_override`)

| Phase | Policy | stalls/s | starved s | max gap |
|---|---|---:|---:|---:|
| 1 | auto (baseline) | 1.68 | 7.00 | 283 ms |
| 2 | `AUTO_TDW1B1`, W1=5 ms | 2.22 | 10.67 | 333 ms |
| 3 | `PAUTO_TDW1B1`, W1=5 ms | **1.28** | **4.34** | **128 ms** |
| 4 | `OFF_BT` (BT exclusive) | **3.18** | 15.64 | 366 ms |
| 5 | auto (restore, control) | 1.62 | 5.99 | 283 ms |

**Reading:** BT-exclusive made stutter *worse* → airtime starvation is not the
dominant mechanism; RF-level packet collisions (dead AFH) are. PS-TDMA gives a
real but partial improvement.

## v1.0 validation (bt-afh-guard active, AAC codec)

Same laptop and headphones, now on AAC. Router channel 11 / 40 MHz, signal
−68…−72 dBm. Bluetooth flow is the controller ACL TX rate, sampled every 2 s;
the AAC stream needs ~46–47 pkts/s.

| Condition | Wi-Fi load | BT flow | Audible |
|---|---|---|---|
| Wi-Fi idle | — | 46–47 pkts/s | clean |
| Ethernet primary, flood over Wi-Fi radio (40 s) | ~1.5 Mbit/s each way, 35% loss | 46 pkts/s steady | clean |
| Wi-Fi only, one download (25 s) | ~1 Mbit/s | 47 pkts/s steady | clean |
| Wi-Fi only, two parallel downloads (28 s) | up to ~6.5 Mbit/s (link max) | steady 16 s, one ~10 s counter dip during a Wi-Fi beacon-loss event | clean |

Live link AFH map (HCI Read AFH Channel Map) with the guard active:
`FF FF FF 00 00 00 00 00 00 60`, i.e. channels 0–23 and 77–78 only. It was
empty in all 121 v0.1 samples.

Still to do: repeat the 600 s `capture-10min.sh` run with the guard active, to
put a stall count next to the v0.1 baseline of 488.

## Interpretation

See `ROOT-CAUSE.md`. Raw telemetry: `data/coex_state-121snapshots.log.gz`
(btc_info dumps, 5 s cadence), `data/stall-buckets-phase1.txt`.
