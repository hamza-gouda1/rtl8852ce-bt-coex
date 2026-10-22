# The fix (v1.0): persistent direct-AFH + AAC

**Status: validated on the reference laptop.** Bluetooth A2DP audio plays
cleanly while 2.4 GHz Wi-Fi is fully loaded and Wi-Fi is the only network link.

This document explains what the v1.0 fix does, why it works, how it was
validated, and how to install, verify and remove it.

---

## TL;DR

| Layer | What it does | File |
|---|---|---|
| **bt-afh-guard** (systemd service) | Tells the Bluetooth controller to stop hopping through the frequencies the Wi-Fi link occupies, using a standard HCI command. Follows channel changes and controller resets, starts at boot. | `scripts/bt-afh-guard`, `systemd/bt-afh-guard.service` |
| **AAC codec** for PipeWire | Better audio than SBC-XQ at roughly half the airtime, so less contention on the shared radio. | `scripts/build-aac-plugin.sh` |
| Installer / uninstaller | One command each, never touches the network stack. | `scripts/install.sh`, `scripts/uninstall.sh` |

```bash
# optional, for AAC (needs build deps, see below)
bash scripts/build-aac-plugin.sh
# installs the service (+ AAC plugin if built)
sudo bash scripts/install.sh
```

---

## 1. Why AFH is the right lever

`ROOT-CAUSE.md` showed that the RTL8852CE's Wi-Fi and BT firmware never
complete their coexistence handshake on Linux (BT reports coex v0, Wi-Fi wants
v7). The consequence that matters is that **adaptive frequency hopping never
learns where the Wi-Fi channel is**. The AFH map stayed empty in 121/121
telemetry samples, so Bluetooth hops through all 79 channels, including the
20–40 MHz block Wi-Fi is transmitting on.

The policy A/B in `MEASUREMENTS.md` showed that giving Bluetooth *exclusive*
airtime made things worse. So the loss is RF collision on shared frequencies,
not starvation of time slots. Fixing that needs frequency separation, which is
exactly what AFH provides.

AFH classification does not have to come from the Wi-Fi firmware. The
Bluetooth Core Specification defines a host command for it:

> **HCI_Set_AFH_Host_Channel_Classification** (OGF 0x03, OCF 0x003F)
> 80-bit field, bit *n* = BT channel *n* (2402 + *n* MHz).
> **1 = unknown (usable), 0 = bad (avoid).** Bit 79 reserved = 0.
> At least 20 channels must remain usable.

The controller combines the host's classification with its own channel
assessment and pushes the resulting hop map to the connected device.

## 2. The bug that hid the fix in v0.1

`scripts/afh-test2.sh` (v0.1) built the mask with the **polarity inverted**.
It set the bits of the *Wi-Fi* channels to 1 and everything else to 0. To the
controller that meant "only the Wi-Fi channels are usable", so the A/B
"masked" phase actually **confined Bluetooth to the Wi-Fi block**. That is the
opposite of the intent, and explains why the v0.1 result was inconclusive.

Two smaller defects in the same script:
- The "clear" step sent an all-zero map (every channel bad). That is invalid
  (fewer than 20 usable channels) and is rejected by the controller, so the
  "unmasked" phase didn't reliably reset anything.
- The "read map" step used opcode `0x03/0x0041`. The correct command is
  **HCI_Read_AFH_Channel_Map**, OGF 0x05 / OCF 0x0006.

All three are fixed in v1.0 (`afh-test2.sh` stays as the A/B experiment;
`bt-afh-guard` is the permanent implementation).

## 3. bt-afh-guard: how it works

Every 5 s the daemon:

1. Finds the connected 2.4 GHz Wi-Fi link via `iw dev <if> info` and reads the
   **center frequency and channel width**. The width matters: an HT40 link on
   channel 11 occupies 2432–2472 MHz, not 2452–2472. v0.1 only used the 20 MHz
   control channel.
2. Adds a 2 MHz guard on each side and converts to BT channels
   (`n = f − 2402`).
3. Builds the 10-byte mask (1 = usable, 0 = avoid), refusing any mask that
   would leave fewer than 20 usable channels.
4. Sends it with `hcitool cmd 0x03 0x003F …`:
   - immediately when the Wi-Fi block changes (roaming, router channel change),
   - immediately when `hci0` comes back up (controller reset, `bluetoothd` restart, resume),
   - and every 60 s anyway, because a controller can reset silently.
5. When Wi-Fi is off or on 5/6 GHz, it sends the all-usable map.

Worked example (reference laptop, router on channel 11 / 40 MHz):

```
Wi-Fi: channel 11 (2462 MHz), width 40 MHz, center1 2452 MHz
Block to avoid: 2430–2474 MHz  ->  BT channels 28–72
Host mask:      FF FF FF 0F 00 00 00 00 00 7E   (34 channels usable)
```

Hop map the controller then actually used for the headphones (Read AFH Channel
Map):

```
before (v0.1 telemetry):  empty / all channels
after  (v1.0):            FF FF FF 00 00 00 00 00 00 60
                          -> channels 0–23 and 77–78 only
```

The controller's own assessment removed a few more edge channels, which is
exactly how host + controller classification is meant to combine.

Configuration overrides (optional) go in `/etc/default/bt-afh-guard`:

```bash
GUARD_MHZ=2     # margin each side of the Wi-Fi block
INTERVAL=5      # check period (s)
REFRESH=60      # forced re-send period (s)
HCI=hci0
```

Check what it would send without root: `bash scripts/bt-afh-guard --dry-run`.

## 4. AAC: better sound *and* less airtime

Many earbuds support AAC (the reference Soundcore P40i advertises SBC + AAC,
no LDAC/aptX). Debian/Ubuntu build PipeWire without AAC because `libfdk-aac`
is non-free, so these earbuds fall back to SBC or SBC-XQ.

| Codec | Typical bitrate | Notes |
|---|---:|---|
| SBC-XQ | ~450–550 kbps | Good quality, heaviest on air |
| SBC | ~330 kbps | Lighter, audibly weaker |
| **AAC** | ~256–320 kbps | As good or better than SBC-XQ, about half the airtime |

On a combo card where every Bluetooth packet competes with Wi-Fi for the same
antenna, airtime is the thing to save. `scripts/build-aac-plugin.sh` builds
**only** the AAC codec plugin from the official PipeWire source of the
**exact** installed version. It links only `libfdk-aac`, `libc` and `libm`.
Then `install.sh` drops it next to the stock codec plugins.

Build dependencies (once):

```bash
sudo apt install build-essential meson ninja-build pkg-config libfdk-aac-dev \
     libdbus-1-dev libsbc-dev libbluetooth-dev libglib2.0-dev libudev-dev
```

After installing, the earbuds show a new top-priority profile
`a2dp-sink: High Fidelity Playback (A2DP Sink, codec AAC)`.

> **Rebuild after a PipeWire upgrade.** The plugin must match the PipeWire
> version. `install.sh` refuses a mismatched build.

## 5. Validation

Reference system: ASUS TUF Gaming F16 (FX608JHR), RTL8852CE (BT USB
0489:e122), Ubuntu 24.04, liquorix 7.0.13, PipeWire 1.2.4, Soundcore P40i on
AAC. 2.4 GHz-only router, channel 11, 40 MHz, signal −68 to −72 dBm (weak,
deliberately hard). Bluetooth flow was sampled every 2 s from the controller's
ACL TX counter. The AAC stream needs ~46–47 packets/s; a stall shows as a drop.

| Test | Wi-Fi load | BT flow | Heard |
|---|---|---|---|
| Wi-Fi idle | — | 46–47 pkts/s | clean |
| Ethernet primary, 40 s flood **over the Wi-Fi radio** to the router | ~1.5 Mbit/s each way, 35% loss | 46 pkts/s steady | clean |
| **Ethernet unplugged**, Wi-Fi only, single download | ~1 Mbit/s | 47 pkts/s steady | clean |
| **Ethernet unplugged**, two parallel downloads | ramping to ~6.5 Mbit/s (link max at this signal) | 47 pkts/s for 16 s, then one ~10 s dip during a Wi-Fi beacon-loss event | **clean throughout** |

Before the fix, the same headphones logged **488 stalls >50 ms per 10 min**
with Wi-Fi only "idle-ish" (`MEASUREMENTS.md`).

The single counter dip happened together with a Wi-Fi `CTRL-EVENT-BEACON-LOSS`
at −70 dBm, i.e. the shared radio briefly struggling at the edge of range. The
earbuds' buffer covered it and nothing was audible. If dropouts ever become
audible under heavy downloads, the next step is on the router (below).

## 6. Router settings that help further

- **Channel width 20 MHz on 2.4 GHz.** A 40 MHz channel blocks 45 of 79 BT
  channels; 20 MHz blocks ~25 and leaves Bluetooth 50+ clean channels.
- **Channel 1 (or 6), away from neighbours.** Less co-channel interference
  means fewer Wi-Fi retransmissions and less airtime.
- **5 GHz Wi-Fi, if the router has it.** It removes the conflict entirely
  (Bluetooth is 2.4 GHz only). The guard then automatically sends the
  all-usable map.
- **Signal strength.** At −70 dBm Wi-Fi uses slow rates, so each packet stays
  on air longer and collides more. Closer is better for both radios.

`bt-afh-guard` follows any of these changes automatically.

## 7. Other things found on the reference laptop

These are not the root cause, but they are worth checking on any affected
machine:

- **Regulatory domain "00" (world).** It restricts 5 GHz to passive scan and
  lowers allowed power. Set your country:
  `options cfg80211 ieee80211_regdom=XX` in `/etc/modprobe.d/`.
- **Invalid btusb option.** `options btusb … disable_scopes=1` is not a real
  parameter. The kernel logs `unknown parameter 'disable_scopes' ignored`.
  Keep only `enable_autosuspend=0`.
- **WirePlumber 0.4 ignores `wireplumber.conf.d/*.conf`.** That syntax is for
  0.5+. On 0.4.x use `~/.config/wireplumber/bluetooth.lua.d/*.lua`.
- **Default output.** After reconnecting, check `wpctl status` that the
  earbuds, not the built-in speakers, are the default sink
  (`wpctl set-default <id>`).
- **`[RX_DCK] S1 RXDCK timeout`** in the kernel log appeared only on boots
  where the BT headphones were streaming. It is the Wi-Fi RF calibration
  being disturbed by the shared antenna. A Wi-Fi radio off/on
  (`nmcli radio wifi off; nmcli radio wifi on`) re-runs calibration if Wi-Fi
  then fails its 4-way handshake.
- **VPNs (e.g. Cloudflare WARP) are not involved.** Coexistence happens far
  below IP. Note that some ISPs block 1.1.1.1/8.8.8.8 directly, which breaks
  WARP's DNS-only mode. Its full-tunnel mode works.

## 8. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Earbuds connect but only "Headset Head Unit" (phone quality), log says `a2dp-sink profile connect failed: Device or resource busy` / `Unable to select SEP` | `bluetoothd` wedged its A2DP state, typically after PipeWire/WirePlumber was restarted mid-stream | `sudo systemctl restart bluetooth`, then reconnect (`scripts/fix-a2dp.sh` does the full sequence). Avoid restarting PipeWire while audio plays. |
| No AAC profile after install | Plugin not loaded yet | Earbuds into the case, `sudo systemctl restart bluetooth`, take them out |
| Is the guard working? | — | `journalctl -t bt-afh-guard` shows `avoiding A-B MHz; mask: …` at each change; `install.sh` prints the live link map |
| Stutter returns after a router change | Nothing needed; the guard re-sends within 5 s | Check the journal line shows the new block |

## 9. Uninstall

```bash
sudo bash scripts/uninstall.sh
```

This removes the service and the AAC plugin and resets the controller to
"all channels usable".

---

*Fix, implementation, measurements and documentation: Hamza Gouda.*
