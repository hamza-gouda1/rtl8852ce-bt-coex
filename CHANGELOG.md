# Changelog

All notable changes to this project are documented here.
Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0.0] - 2026-10-23

The fix. Validated with Wi-Fi as the only link under saturating download
load: clean A2DP audio. See `docs/SOLUTION.md`.

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
