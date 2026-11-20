# Changelog

All notable changes to this project are documented here.
Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [1.1.1] - 2026-11-20

### Fixed
- `install.sh` used `systemctl enable --now`, which leaves an already-running
  daemon untouched. Upgrades therefore kept running the old in-memory copy
  under the old, unhardened unit. The installer now restarts the service and
  prints only the log lines written by the restarted daemon. Before, it
  printed the last journal line, which could be left over from the old
  process.

### Verified
- On the reference laptop, the restarted 1.1.1 daemon ran under the hardened
  unit with only `CAP_NET_ADMIN` and `CAP_NET_RAW`, and `NoNewPrivileges` set.
  It programmed the channel-1 / 20 MHz mask through `hci-cmd.py`, and the
  controller accepted it with status 0x00.

## [1.1.0] - 2026-11-20

### Added
- `scripts/bt-afh-guard`: verified sends — every command goes through
  `scripts/hci-cmd.py` (stdlib-only raw HCI sender that waits for the
  controller's Command Complete event and exits with its status byte) or a
  `hcitool` fallback that parses the status from the dump; the daemon logs
  the real HCI status on rejection.
- `scripts/bt-afh-guard --status` (root): backend, Wi-Fi block, host mask and
  the live AFH hop map of every connected link with its Wi-Fi overlap.
- Live-map readback: after every successful set and refresh, each connected
  ACL handle is read with `HCI_Read_AFH_Channel_Map` and logged as one
  compact line (`live map handle 4: 34 ch used, 0 overlap with Wi-Fi …`).
- Hold-down: when the 2.4 GHz link drops, the last mask is kept for `HOLD_S`
  (default 30 s, 0 disables) instead of immediately clearing, so flapping
  links no longer bounce the controller between restricted and open; state
  transitions are logged, not every tick.
- `--version`, `--help`, `--once`; config validation for
  `/etc/default/bt-afh-guard` (out-of-range values are rejected with a
  warning and the default applies); `systemd/bt-afh-guard.default` example.
- Dependency-free test suite (`tests/run.sh` plus a Python unittest suite for `hci-cmd.py`) covering the mask
  logic against recorded iw fixtures, the verified sender (both backends via
  stubs), live-map parsing and the hold-down state machine; CI workflow
  renamed to `ci` with a tests job.
- `scripts/wifi-health-capture.sh` + `scripts/analyze-wifi-health.py`: sample
  Wi-Fi link health + A2DP transport state every 2 s and compare beacon
  loss / retries / disconnects while audio plays vs is suspended — the
  Bluetooth → Wi-Fi direction, previously unmeasured.
- `scripts/afh-positive-control.sh`: three-phase positive control (open →
  restricted → confined) that deliberately confines Bluetooth to the Wi-Fi
  block to test whether overlap itself produces stalls — the causal test the
  controlled rerun could not provide.
- Hardened systemd unit (documented sandboxing: `CAP_NET_RAW`+`CAP_NET_ADMIN`
  only, `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`,
  `ProtectKernelTunables`, `ProtectControlGroups`,
  `RestrictAddressFamilies=AF_BLUETOOTH AF_NETLINK AF_UNIX`).
- Channel-map figure in the README (`docs/img/afh-channel-map.svg`), drawn
  from the measured AFH maps in `docs/MEASUREMENTS.md`.
- shellcheck CI workflow.
- `LICENSES/` with the full GPL-2.0 and BSD-3-Clause texts; SPDX headers in
  every script and the systemd unit.

### Changed
- Bound the diagnosis and workaround claims to the single-laptop measurements
  and the controlled rerun, which could not isolate the AFH guard's effect.
- `scripts/re-pair-p40i.sh` is now `scripts/re-pair-device.sh`. It and
  `fix-a2dp.sh` and `bt-reset-repair.sh` take the device's Bluetooth address
  as an argument (or `BT_DEV`) instead of a hardcoded one.
- `LICENSE` now holds the full GPL-2.0 text, so GitHub detects it; the
  per-folder licensing is in `LICENSES/README.md`.
- install.sh detects the controller via `/sys/class/bluetooth/$HCI` plus a
  verified probe (no hard `hciconfig` dependency), installs `hci-cmd.py` to
  `/usr/local/lib/bt-afh-guard/`, and prints installed vs repo daemon
  version, warning before replacing an older copy.
- uninstall.sh resets the classification through the verified sender and
  reports the actual HCI status.

### Fixed
- shellcheck warnings in `afh-test2.sh` (unused variable), `capture-10min.sh`
  and `swap-modules.sh`.
- `bt-afh-guard` no longer logs "sent" when the controller rejected the
  classification (hcitool's exit status does not reflect the HCI status
  byte).
- Only the first wireless interface was considered; the 2.4 GHz blocks of
  all interfaces are now unioned, and links without a `center1` field fall
  back to the control frequency (over-blocking one side, never under-blocking).
- A Wi-Fi block that would leave fewer than 20 usable channels now produces
  a warning instead of a silent all-usable send.
- SC2086 (mask word-splitting) annotated with a justified disable directive.

## [1.0.0] - 2026-10-23

Workaround validated on one laptop with Wi-Fi as the only link under
saturating download load and clean A2DP audio. See `docs/SOLUTION.md`.

### Added
- `scripts/bt-afh-guard` + `systemd/bt-afh-guard.service`. A persistent
  direct-AFH daemon:
  - reads the live Wi-Fi center frequency **and channel width**,
  - programs `HCI_Set_AFH_Host_Channel_Classification`,
  - re-sends on channel change, controller reset/`bluetoothd` restart, and every 60 s,
  - clears the mask when Wi-Fi leaves 2.4 GHz.
  - Includes `--dry-run`; overrides go in `/etc/default/bt-afh-guard`.
- `scripts/build-aac-plugin.sh`: builds PipeWire's AAC Bluetooth codec
  (`libspa-codec-bluez5-aac.so`) from the official source of the exact
  installed PipeWire version. That gives better sound than SBC-XQ at about
  half the airtime.
- `scripts/install.sh` / `scripts/uninstall.sh`: one-command install and
  removal. They never touch the network stack. The installer refuses an AAC
  build that doesn't match the installed PipeWire.
- `docs/SOLUTION.md`: how the fix works, validation results, router
  recommendations, related findings, and troubleshooting.

### Fixed
- `scripts/afh-test2.sh`: **AFH mask polarity was inverted** (Wi-Fi channels
  were marked usable and every other channel bad). That confined Bluetooth to
  the Wi-Fi block, the opposite of the intent, and explains the inconclusive
  v0.1 A/B result. Also fixed:
  - "Read AFH map" now uses the correct opcode (OGF 0x05 / OCF 0x0006 instead of 0x03 / 0x0041).
  - The "clear" step restores all channels instead of sending an invalid all-zero map.
- `CITATION.cff`: repository URL now points to the actual repository.

### Changed
- README: "Just fix it" quick start, v1.0 status, updated roadmap and FAQ.

## [0.1.0] - 2026-09-18

### Added
- Patch 0001: rtw89 debugfs coex telemetry on kernels without
  `CONFIG_CFG80211_DEBUGFS` (liquorix et al.) — mounts the tree without
  the wiphy debugfs dir and provides local replacements for the cfg80211
  locked debugfs helpers.
- Patch 0002: live coex policy tuning via module parameters
  `btc_policy_override` and `btc_w1_dur_ms` (runtime, per-A2DP-action).
- `scripts/swap-modules.sh` — verified 4-module swap with automatic
  rollback (explicit full-set unload; stock modules never deleted).
- `scripts/capture-10min.sh` — 600 s correlated capture: HCI trace,
  traffic/signal sampling, `btc_info` coex state every 5 s.
- `scripts/btc-policy-test.sh` — five-phase policy A/B with per-phase
  Bluetooth stall counts.
- `scripts/afh-test2.sh` — direct-AFH HCI workaround: computes the BT
  channel mask from the live Wi-Fi frequency, applies it via
  `Set AFH Host Channel Classification`, A/B-tests with capture.
- `scripts/fix-a2dp.sh`, `bt-reset-repair.sh`, `re-pair-p40i.sh` —
  escalating repair kit for wedged A2DP/HFP speaker states.
- `docs/` — root-cause analysis with telemetry evidence, full
  measurement tables, usage guide with hard-won gotchas.
- `data/` — raw btc_info telemetry (121 snapshots) and traffic log.

### Known limitations
- The direct-AFH workaround is demonstrated end-to-end but not yet
  stress-validated under sustained Wi-Fi download load.
- AFH mask is not yet persistent across reconnects/channel changes.
- Control H2C features unsupported by Wi-Fi firmware 0.27.129.4
  (`fcxslots`, `fcxbtafh`, …) cannot be restored from the driver side.
