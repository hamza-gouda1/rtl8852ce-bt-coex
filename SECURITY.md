# Security policy

## Reporting a vulnerability

Report vulnerabilities privately by email to **Hamza Gouda <hraafat357@gmail.com>**
or through [GitHub private reporting](https://github.com/hamza-gouda1/rtl8852ce-bt-coex/security/advisories/new).
Please do not open a public issue for a security report.

Include what you found, the affected commit, and the steps to reproduce it. You
will get an acknowledgement within a few days.

## Sensitive surfaces

- `scripts/install.sh`, `scripts/swap-modules.sh` and `scripts/build-aac-plugin.sh` run as
  root and replace kernel modules or system libraries. Anything that lets them act on
  untrusted input or paths is a vulnerability.
- `scripts/bt-afh-guard` and the units in `systemd/` run as a root service and send
  commands to the Bluetooth controller.
- The patches in `patches/` change a kernel driver. Review them before building a module.

## Responsible disclosure

Please allow 90 days to release a fix before disclosing details publicly.
