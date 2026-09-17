# Root Cause: RTL8852CE BT/Wi-Fi coexistence on Linux

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

## The failure chain

1. **Protocol handshake fails.** The BTC driver wants BT coex protocol v7
   (`bt_desired: 7`). The BT firmware (upstream `rtl_bt/rtl8852cu_fw_v2`,
   verified byte-identical to linux-firmware HEAD) reports version **0**.
   Observed continuously across a 10-minute capture (121 snapshots).
2. **Control H2Cs unsupported.** The feature negotiation table shows the Wi-Fi
   firmware answering 0 (unsupported) for `fcxslots, fcxcysta, fcxstep,
   fcxnullsta, fcxmreg, fcxbtver, fcxbtscan, fcxbtafh, fcxbtdevinfo` —
   everything except the passive BT-report channel (`fcxbtcrpt`, works) and the
   TDMA channel (`fcxtdma`, version-mismatched: firmware speaks v4, driver
   composes v3).
3. **AFH never engages.** With the AFH control path dead, the BT controller's
   AFH map stays empty. Wi-Fi on channel 9 or 11 sits inside BT's hop range, so
   every WLAN transmission is a potential packet collision for the BT link.
4. **The mailbox half-works.** A2DP-related mailbox messages accumulate NACKs
   at a ~50% rate during playback (41,154 NACKs / 10 min), plus recurring
   `len-mismatch` errors in the coex DM.

## Why audio stutters

With no AFH, BT is reduced to time-sharing the band blind. Measured over 600 s
of A2DP playback (37,149 ACL frames): **488 delivery stalls >50 ms, 74 s of
accumulated starvation (12.3%)**, worst single gap 283 ms — 14× longer than the
20 ms WLAN slot the active policy (`AUTO_TD20B1`) promises. The policy is not
being enforced as designed.

The decisive experiment: forcing **BT-exclusive** coexistence (`OFF_BT`) —
which should eliminate all airtime competition — made stutter *worse*
(3.18 stalls/s vs 1.68 baseline), while a PS-TDMA policy variant improved it
(1.28 stalls/s). Conclusion: the dominant loss mechanism is **packet-level RF
collision on the shared band, not airtime arbitration** — which is why slot
tuning alone cannot fix it and why AFH (frequency separation) is the correct
target.

## The workaround

BT controllers accept their channel-avoidance map directly from the host via a
standard HCI command — `Set AFH Host Channel Classification` (OGF 0x03, OCF
0x003F, 10-byte channel bitmask) — no vendor mailbox required. Mapping the live
Wi-Fi frequency to BT channels (`f = 2402 + n MHz`) and masking that block
gives the BT side the frequency separation the broken mailbox was supposed to
provide. This is the same information Realtek's Windows drivers deliver
automatically.

See `scripts/afh-test2.sh` for the reference implementation (computes the mask
from the live interface, verifies the stream is up, A/B tests with HCI-level
capture).
