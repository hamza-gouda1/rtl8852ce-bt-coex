# Strongly Indicated Cause — RTL8852CE Firmware Coexistence

## Hardware topology

The RTL8852CE is a combo card: Wi-Fi on PCIe (`rtw89_8852ce`), Bluetooth on USB
(`btusb`, Realtek BT core, Foxconn 0489:e122 on ASUS TUF). Both halves share one
antenna pair and the 2.4 GHz band. Coordination happens over an inter-firmware
mailbox: the Wi-Fi firmware's coexistence driver (BTC) exchanges H2C/C2H
messages with the BT firmware, negotiates time-division (TDMA) policies, and —
critically — tells the BT side which channels to avoid (AFH).

## How we got visibility

The stock driver builds without debugfs on kernels lacking
`CONFIG_CFG80211_DEBUGFS` (liquorix). Patch 0001 makes the debugfs tree build
and mount anyway; the result is `/sys/kernel/debug/rtw89/btc_info`, a full dump
of the coexistence engine: protocol versions, link state, TDMA slot tables,
mailbox statistics, AFH maps.

## Observations and indicated failure chain

1. **Protocol version mismatch is reported.** The BTC driver wants BT coex protocol v7
   (`bt_desired: 7`). The BT firmware (upstream `rtl_bt/rtl8852cu_fw_v2`,
   verified byte-identical to linux-firmware HEAD) reports version **0**.
   Observed continuously across a 10-minute capture (121 snapshots).
2. **Control H2Cs unsupported.** The feature negotiation table shows the Wi-Fi
   firmware answering 0 (unsupported) for `fcxslots, fcxcysta, fcxstep,
   fcxnullsta, fcxmreg, fcxbtver, fcxbtscan, fcxbtafh, fcxbtdevinfo` —
   everything except the passive BT-report channel (`fcxbtcrpt`, works) and the
   TDMA channel (`fcxtdma`, version-mismatched: firmware speaks v4, driver
   composes v3).
3. **The Wi-Fi-side AFH report stays empty.** This suggests a failed channel
   coordination path. The report alone does not determine the Bluetooth
   controller's live hop map, which needs an independent HCI read.
4. **The mailbox half-works.** A2DP-related mailbox messages accumulate NACKs
   at a ~50% rate during playback (41,154 NACKs / 10 min), plus recurring
   `len-mismatch` errors in the coex DM.

## Why audio stutters

The initial 600-second capture contained 37,149 ACL frames and 488 delivery
gaps over 50 ms, totaling 74 seconds of gaps. These host-level delivery gaps
measure transport timing, rather than directly measuring audible silence or
RF collisions.

Selecting the BT-exclusive policy increased the stall rate from 1.68 to 3.18
per second, while a PS-TDMA variant reduced it to 1.28. Combined with the
reported firmware mismatch and mailbox failures, this strongly indicates a
coexistence coordination problem. The experiment cannot establish that a
particular interference mechanism dominates.

The [controlled SBC rerun](MEASUREMENTS.md#controlled-sbc-rerun-2026-11-08)
kept the codec and requested load fixed, but both classifications already had
zero measured Wi-Fi overlap in the live link maps. It could not isolate the
workaround's effect. Additional hardware and a test that produces distinct
live maps are needed to test that causal explanation.

## The workaround

BT controllers accept their channel-avoidance map directly from the host via a
standard HCI command — `Set AFH Host Channel Classification` (OGF 0x03, OCF
0x003F, 10-byte channel bitmask) — no vendor mailbox required. Mapping the live
Wi-Fi frequency to BT channels (`f = 2402 + n MHz`) and masking that block
supplies an additional channel-avoidance hint to the Bluetooth controller.
The combined AFH/AAC workaround was validated on one laptop. The controlled
rerun leaves the guard's independent contribution unresolved.

Bit polarity matters: in the 80-bit map, **1 = usable ("unknown"), 0 = bad**,
bit 79 is reserved, and at least 20 channels must stay usable. The v0.1 test
script had this inverted (fixed in v1.0).

The permanent implementation is `scripts/bt-afh-guard`, a systemd service that
tracks the live Wi-Fi center frequency and width and re-programs the map on
every change and controller reset. `scripts/afh-test2.sh` remains as the A/B
experiment. Results and validation: [`SOLUTION.md`](SOLUTION.md).
