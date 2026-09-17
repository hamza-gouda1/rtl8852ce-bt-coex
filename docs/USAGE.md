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

## Workaround layer

- **afh-test2.sh** — the centerpiece: computes the BT channel mask from the
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
- Kernel builds reject `__DATE__`/`__TIME__` (`-Werror=date-time`), and a
  failed compile can leave a stale `.ko`: always check mtime vs source.
