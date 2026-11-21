# Measurements

The initial measurements used a single ASUS TUF Gaming F16 (FX608JHR, Foxconn
RTL8852CE), Ubuntu 24.04, liquorix 7.0.13, Soundcore P40i earbuds (A2DP,
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

**Reading** — BT-exclusive increased stalls and PS-TDMA reduced them in this
short comparison. The results support a coexistence investigation but do not
isolate RF collisions as the dominant mechanism. The controlled rerun below
records the limits of the causal evidence.

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

## Controlled SBC rerun (2026-11-08)

On the same RTL8852CE laptop (liquorix 7.0.13-3, PipeWire 1.2.4), I used
the Soundcore P40i earbuds on SBC and a continuous synthetic pink-noise
stream. Wi-Fi stayed on 2.4 GHz, primary channel 5 with a 40 MHz channel
centered at 2422 MHz. The codec, Bluetooth link, Wi-Fi channel and route were
checked before and after each trial.

Four adjacent pairs balanced the order of two host classifications. I paused
the guard and sent each mask with HCI Set AFH Host Channel Classification.
**Open** allowed all 79 Bluetooth channels at the host level. **Restricted**
excluded channels in the Wi-Fi block with a 2 MHz margin. Each trial waited
6 s after programming the classification, then ran a 30 s ICMP load bound
to Wi-Fi and directed at the local gateway (1200-byte payload, one request
every 8 ms). I read the live link AFH map before and after each load and
counted outgoing ACL gaps at the host-to-controller interface for the earbud
connection in the middle 28 s.

| Trial | Host classification | ICMP sent / received | ACL TX packets | Gaps > 50 ms | p95 gap (ms) | Worst gap (ms) | Live channels overlapping Wi-Fi, before / after |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | Open | 3393 / 2099 | 1752 | 0 | 16.378 | 17.030 | 0 / 0 |
| 2 | Restricted | 3751 / 3751 | 1752 | 0 | 16.129 | 16.773 | 0 / 0 |
| 3 | Restricted | 3751 / 3750 | 1751 | 0 | 16.129 | 16.909 | 0 / 0 |
| 4 | Open | 3749 / 3749 | 1750 | 0 | 16.316 | 17.005 | 0 / 0 |
| 5 | Restricted | 3743 / 3743 | 1754 | 2 | 16.193 | 84.151 | 0 / 0 |
| 6 | Open | 3741 / 3741 | 1750 | 0 | 16.157 | 16.954 | 0 / 0 |
| 7 | Open | 3751 / 3751 | 1751 | 0 | 16.184 | 16.939 | 0 / 0 |
| 8 | Restricted | 3750 / 3750 | 1750 | 0 | 16.114 | 16.527 | 0 / 0 |

The host commands differed, but every live link map already
excluded all measured Wi-Fi overlap in both conditions. The open condition
had 0 gaps over 50 ms in 7003 outgoing packets, and restricted had 2 in
7007. The first trial also had much lower ICMP delivery despite the same
requested pacing. These results do not isolate the effect of excluding
Wi-Fi frequencies, and the gap counts do not establish that either
classification performs better.

A separate 10 s pilot per setting applied the classification before
reconnecting the earbuds. The new links used 21 channels with the open
classification and 27 with the restricted classification. Both still had
zero Wi-Fi overlap before and after the load. This confirms that allowing
every channel in the host command did not recreate an overlapping live map
on this setup. The guard was restored after both runs.

## Guard-active capture (2026-11-21, ~02:26–02:36)

Same laptop, earbuds on AAC, guard v1.1.1 active, Wi-Fi channel 1 / 20 MHz
(block 2400–2424 MHz), signal −66 to −77 dBm across the session. This boot
had degraded radio conditions (144 `CTRL-EVENT-BEACON-LOSS`, 10 disconnects,
recurring `[RX_DCK] S1 RXDCK timeout` in the kernel log). Recorded with
`scripts/hci-acl-capture.py` (decoder-free monitor-channel recorder; btmon
aborts on this stream — see the notes below the rerun section).

| Metric (600 s A2DP playback, guard active) | Value |
|---|---:|
| TX ACL packets | 23,142 (~38.6/s; healthy AAC is ~46/s) |
| Stalls > 50 ms | **1,099** (4.7% of gaps) |
| Accumulated starvation | **204.9 s (34.2% of wall time)** |
| p95 / worst gap | 614.1 ms / 1,988.1 ms |
| Live map (verified every 60 s) | 52 ch used, **0 overlap** with Wi-Fi 2400–2424 |
| Guard rejects / flap cycling | 0 |

The live hop map had **zero Wi-Fi overlap throughout the window** — the
mechanism the guard addresses was not in play, yet the stream starved for a
third of the wall time, with stalls clustered (ten bursts, largest 276 stalls
over ~95 s) and a lower packet rate than a healthy AAC stream.

Reading:

- The guard-active capture shows that substantial stalls can occur while
  the measured live channel map has zero Wi-Fi overlap. The effect of the
  guard on that session remains unmeasured because there was no paired
  capture with the guard disabled.
- The comparison to the 488-stall baseline is **confounded** (codec SBC-XQ vs
  AAC, night, signal, radio state) and carries no guard-vs-no-guard meaning.
  The clean causal comparison is same-night paired: guard on vs guard off
  with everything else identical; it has not been run yet.

## Interpretation

See `ROOT-CAUSE.md`. Raw telemetry: `data/coex_state-121snapshots.log.gz`
(btc_info dumps, 5 s cadence), `data/stall-buckets-phase1.txt`.
