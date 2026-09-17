# Contributing

The single most valuable contribution is **telemetry from hardware we
haven't seen yet**.

## The gold: `btc_info` dumps

If you have an RTL8852CE (or 8852B/8851B — the handshake gap may be
family-wide), build patch 0001 against your kernel source and post:

```bash
sudo cat /sys/kernel/debug/rtw89/btc_info > btc_info-<laptop-model>.txt
```

Two things matter per dump: the `BT_FW_coex:` line (does your BT firmware
report coex version 0 too?) and the `afh_map:` line (empty or populated?).
Attach it to an issue with your laptop model, kernel version, and
`linux-firmware` package version.

## Bug reports

- Run the failing script with its built-in diagnostics (most scripts write
  logs on failure) and attach them.
- For audio-stutter reports: a `scripts/capture-10min.sh` run during
  actual stutter is worth a thousand "it stutters sometimes".

## Patch guidelines

- Patches target the vanilla kernel.org source for the version named in
  the filename; each patch must apply with `patch -p1` from the kernel
  root and be verified against a real build.
- Match upstream style; explain *why* in the commit message, *what
  broke* without it.

## Code style

Scripts are POSIX-leaning bash with `set -u`, SCRIPT_DIR-anchored paths,
and full-set verification for any destructive operation. Every script
that modifies system state must back up and be able to roll back.
