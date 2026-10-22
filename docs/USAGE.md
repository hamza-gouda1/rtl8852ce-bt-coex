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
- **btc-policy-test.sh** — five 50 s phases cycling coex policies via the
  `btc_policy_override` module parameter (baseline → TDW1B1 → PS-TDMA →
  BT-exclusive → restore). Requires patch 0002.

## The fix (v1.0) — start here

- **install.sh** — `sudo bash scripts/install.sh`. Installs `bt-afh-guard` as a
  systemd service, plus the AAC plugin if you built it. It prints the guard's
  first log line and the live link AFH map. It never touches the network.
- **bt-afh-guard** — the daemon. `bash scripts/bt-afh-guard --dry-run` shows
  the Wi-Fi block and the exact mask it would send (no root needed).
  `journalctl -t bt-afh-guard` shows every change.
- **build-aac-plugin.sh** — builds PipeWire's AAC codec for your installed
  PipeWire version, as a normal user. Rebuild after PipeWire upgrades.
- **uninstall.sh** — removes the service and plugin and resets the controller
  to "all channels usable".

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
- **re-pair-p40i.sh** — scripted remove/scan/pair/trust/connect.

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
