# Usage guide

All scripts back up originals and/or are runtime-only unless noted.
Run order matters for some; each header explains itself.

## Driver layer

- **swap-modules.sh** — install/reload the instrumented rtw89 build.
  Explicitly unloads ALL FOUR rtw89 modules (a plain `modprobe -r` of the top
  module silently leaves the stock core loaded — the bug that cost us six
  debug runs). Auto-rollback restores stock modules on any failure and writes
  `swap-failure.log` first. ~10 s Wi-Fi interruption; Bluetooth untouched.

## Measurement layer

- **capture-10min.sh** — 600 s correlated capture: `btmon` HCI trace,
  traffic/signal every 2 s, `btc_info` coex state every 5 s. Music + real
  traffic during the window; the stall analysis needs actual stutter.
  Run it **without sudo** (it calls sudo internally); its btmon step aborts
  with a glibc fortify error while decoding the A2DP media stream on
  bluez 5.72 (recording stops ~104 s in), so for HCI traces use
  **hci-acl-capture.py** below.
- **hci-acl-capture.py** — `sudo python3 scripts/hci-acl-capture.py <seconds>
  [outfile]`: decoder-free ACL TX recorder on the kernel monitor channel,
  the crash-proof replacement for btmon traces. Writes
  `# hci-acl-tx v1` text (`<seconds> <handle> <dlen>` per line); the
  outfile stays inside the current directory (relative paths only,
  O_NOFOLLOW). Ctrl-C stops early with the data written so far.
- **analyze-stalls.sh** — `bash scripts/analyze-stalls.sh <capture-dir|file>
  [HANDLE]`: counts the delivery gaps > 50 ms of the audio link (busiest ACL
  TX handle unless overridden) from either a capture-10min.sh directory or a
  native hci-acl-capture.py file, and prints stalls, accumulated starvation,
  p95 and worst gap — the metric next to the 488-stall baseline.
- **btc-policy-test.sh** — five 50 s phases cycling coex policies via the
  `btc_policy_override` module parameter (baseline → TDW1B1 → PS-TDMA →
  BT-exclusive → restore). Requires patch 0002.

## The workaround (v1.1) — validated on one laptop

- **install.sh** — `sudo bash scripts/install.sh`. Installs `bt-afh-guard`,
  `hci-cmd.py` (to `/usr/local/lib/bt-afh-guard/`) and the systemd service,
  plus the AAC plugin if you built it. It probes the controller through the
  verified sender, prints installed vs repo daemon version (warning before
  replacing an older copy), and prints the live link AFH map. It never
  touches the network.
- **bt-afh-guard** — the daemon. Modes:
  - *(no mode)* — run as a daemon (what the systemd unit does).
  - `--dry-run` — print the Wi-Fi block and the exact mask that would be sent
    (no root needed). Warns when the block would leave fewer than 20 usable
    channels.
  - `--status` — backend, Wi-Fi block, host mask, and the **live AFH
    hop map of every connected link** with its overlap against the Wi-Fi
    block. Read-only.
  - `--once` — run one daemon cycle and exit.
  - `--version` / `--help`.
  Env overrides in `/etc/default/bt-afh-guard` (see
  `systemd/bt-afh-guard.default` for a commented example): `GUARD_MHZ`,
  `INTERVAL`, `REFRESH`, `HOLD_S` (seconds to keep the last mask after a
  Wi-Fi loss; 0 disables the hold-down) and `HCI`. Invalid values are
  rejected with a warning and the default applies. Logs go to the journal
  (`journalctl -t bt-afh-guard`) and include state transitions, the real HCI
  status on rejection, and one live-map line per link after every send.
  Example: `bash scripts/bt-afh-guard --dry-run` on the reference laptop:
  `Wi-Fi block: 2400-2424 MHz` / mask `0x00 0x00 0x80 FF ... (56/79 channels usable)`.
- **build-aac-plugin.sh** — builds PipeWire's AAC codec for your installed
  PipeWire version, as a normal user. Rebuild after PipeWire upgrades.
- **uninstall.sh** — removes the service, daemon and helper, resets the
  controller through the verified sender (reports the real HCI status) and
  removes the plugin.

Full explanation: [`SOLUTION.md`](SOLUTION.md).

## Measurement layer additions (v1.1)

- **wifi-health-capture.sh** — `bash scripts/wifi-health-capture.sh <seconds>
  [IFACE]` samples every 2 s: `iw dev <if> link` (signal, tx/rx bitrate),
  `iw dev <if> station dump` (tx retries, tx failed, beacon loss, rx drop
  misc, packet counters), the A2DP transport state from the desktop session
  (`pactl list sinks short`), and wpa_supplicant BEACON-LOSS / DISCONNECTED /
  CONNECTED events from journalctl (requires the user to be in the
  `systemd-journal`/`adm` group). Writes one CSV with a header. No root
  needed except journal access; under sudo `pactl` cannot see the user's
  audio session and A2DP reads UNKNOWN.
- **analyze-wifi-health.py** — `python3 scripts/analyze-wifi-health.py
  <capture.csv>` compares beacon-loss rate, retries/s, failures/s, disconnect
  and beacon-loss events, and median tx/rx bitrate between A2DP RUNNING and
  SUSPENDED samples (counters converted to deltas; resets clamp to 0), as a
  Markdown table with the sample counts.
- **afh-positive-control.sh** — `sudo bash scripts/afh-positive-control.sh
  [IFACE] [HANDLE]`: three phases (open → restricted → confined), where
  *confined* deliberately confines Bluetooth to the Wi-Fi block (the v0.1
  inverted mask; refused if that would leave fewer than 20 usable channels).
  Reconnects the earbuds per phase, reads the live map before/after a 30 s
  ICMP load, and counts ACL gaps > 50 ms from btmon. Measures whether
  channel overlap itself produces stalls — the causal test the docs lack.

Full explanation: [`SOLUTION.md`](SOLUTION.md).

## Workaround layer (experiments)

- **afh-test2.sh** — the A/B experiment (mask polarity fixed in v1.0): computes the BT channel mask from the
  live Wi-Fi frequency, programs it via HCI `Set AFH Host Channel
  Classification`, and A/B-tests 45 s masked vs 45 s unmasked. Verifies the
  A2DP stream is actually up first (ACL packet-counter delta — robust under
  sudo, unlike audio-session checks).

## Bluetooth repair kit (when the speaker wedges)

RTL8852CE + BlueZ can leave a speaker stuck in handsfree-only or
connected-without-profiles. In escalating order:

- **fix-a2dp.sh** — restart bluetoothd (clears the cached A2DP SEP state).
  Cures "handsfree only" / "no a2dp-sink profile".
- **bt-reset-repair.sh** — controller power-cycle (`btmgmt power off/on`) +
  re-pair. Cures zombie SCO sessions keeping A2DP refused.
- **re-pair-device.sh** — scripted remove/scan/pair/trust/connect.

The three repair scripts take your device's Bluetooth address as the first
argument (or `BT_DEV`); find it with `bluetoothctl devices`.

## Known gotchas (learned the hard way)

- `modprobe -r <top-module>` may leave dependency modules loaded — always
  unload and verify the full set (see swap-modules.sh).
- `hciconfig` wraps long counter lines; parse with `grep -oP 'acl:\K[0-9]+'`,
  not positional fields.
- `pactl` under `sudo` cannot see the user's audio session — verify playback
  with controller counters instead.
- Restarting PipeWire/WirePlumber while A2DP is streaming can wedge
  `bluetoothd` ("a2dp-sink profile connect failed: Device or resource busy",
  "Unable to select SEP"). Resetting the earbuds doesn't help; restarting
  `bluetoothd` does (fix-a2dp.sh).
- The AFH host map is 1 = usable, 0 = avoid. An all-zero map is invalid and
  is rejected by the controller.
- WirePlumber 0.4.x silently ignores `wireplumber.conf.d/*.conf`; use
  `bluetooth.lua.d/*.lua`.
- Kernel builds reject `__DATE__`/`__TIME__` (`-Werror=date-time`), and a
  failed compile can leave a stale `.ko`: always check mtime vs source.
