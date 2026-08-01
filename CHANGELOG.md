# Changelog

## v2.3 — 2026

- Added `.gitattributes`, forcing LF line endings for `.sh`/`.md`/`.conf`
  files regardless of the platform used to commit them. Prompted by
  moving development to a Windows workstation: Windows editors and Git
  for Windows can introduce CRLF line endings, which break or silently
  misbehave when a shell script is later run on the Pi — this repo's
  scripts only ever execute on Linux, never on the machine used to edit
  them, so this matters more than it would for a typical cross-platform
  project.
- No functional script changes.

## v2.2 — 2026

**Sanitized for public/GitHub release.** No functional changes to any
script's behavior — this release only touches documentation and
default/example values, in preparation for publishing the project
publicly.

- Replaced the worked example used throughout both PDF manuals (which
  had been the actual production frequencies of the original build
  station) with a fresh, internally-consistent, entirely fictitious
  example (3600/7100/4700 kHz). All derived math — center frequency,
  per-channel offsets — was recomputed and verified, not just
  find-and-replaced.
- Removed the real production hostname (used as the example hostname
  and Cloudflare Tunnel name throughout both manuals and as the
  suggested default in `00-configure.sh`) in favor of a generic
  placeholder (`sdr-station-1`).
- Removed the suggestive timezone default (which revealed the original
  build's approximate location) from `00-configure.sh`; timezone is now
  a required, non-defaulted entry.
- Added `.gitignore`, excluding `hamhfrx.conf` and `channels.conf` (the
  two files that ever contain real secrets/frequencies/hostnames for an
  actual deployment) along with build artifacts and logs.
- **One open judgment call, left for the maintainer to decide rather
  than changed unilaterally:** `INSTALL_ROOT` still defaults to
  `/opt/hamhfrx1` in `00-configure.sh`, and this path is used
  consistently across every phase script. It's a structural convention
  (the same path would be used by any deployment of this tool), not a
  secret, but it is derived from the original station's name. Renaming
  it project-wide is straightforward but touches every script file —
  worth doing deliberately in a dedicated pass if you want it fully
  generic, rather than folded into this release.

## v2.1 — 2026

**Bugfix**, found during a real production migration from the original
hand-built (v1.x-era) station to `channels.conf`-driven v2.0 tooling.

- Fixed `05-sdrangel-config.sh`: the provisioning script was written to a
  `mktemp` temp file owned by the invoking (admin) user, then copied into
  place with `sudo -u hamsvc cp` — which fails with `Permission denied`,
  since `hamsvc` has no read access to a file it doesn't own and isn't
  root. Fixed by copying as root (`sudo cp`) and then handing ownership
  to `hamsvc` afterward (`sudo chown`). Confirmed against a real
  cross-user permission reproduction, not just re-read for correctness.
- No other instance of this pattern exists elsewhere in the codebase
  (checked: `06-streaming.sh` writes its files directly via
  `sudo -u hamsvc tee`, which doesn't go through an intermediate
  root/admin-owned temp file and was never affected).

No functional or configuration-format changes in this release — a
`channels.conf` or `hamhfrx.conf` from v2.0 works unchanged with v2.1.

## v2.0 — 2026

**Channel configuration redesign — the headline change.**

- Replaced the fixed three-channel (`CH1`/`CH2`/`CH3`) model with
  `channels.conf` — a plain, hand-editable file supporting any number of
  channels.
- Added **AM** support alongside LSB/USB. AM uses a genuinely different
  SDRangel channel type (`AMDemod`, symmetric bandwidth) than SSB's
  signed `rfBandwidth`/`lowCutoff` pair — this is real branching logic,
  not just a label.
- Systemd services and Icecast mountpoints are now named after the
  channel's mountpoint string, not a positional index, so reordering
  `channels.conf` doesn't orphan a running service.
- Phase 6 now actively removes services for any mountpoint no longer
  present in `channels.conf` when re-run, instead of leaving stale
  processes behind.
- Center frequency and sample-rate-vs-span checking are computed
  automatically from whatever channels are currently configured, in both
  the configuration wizard and phase 5.
- ALSA loopback device count now sizes itself to the channel count
  automatically (`lib/channels.sh`, shared by phases 0/5/6).
- Build manual updated to document the general N-channel/AM case
  alongside the original 3-channel worked example, and now ships
  bundled in this package as `hamhfrx-build-manual.pdf`.

**Phases 5 and 6 added** (were not present in v1.x):

- `05-sdrangel-config.sh` — ALSA loopback, `sdrangelsrv` systemd unit
  (real-time scheduling + module-load ordering), REST-API provisioning.
- `06-streaming.sh` — ffmpeg MP3 encode + Icecast push, one systemd
  service per channel, `StartLimitIntervalSec=0` for indefinite
  automatic recovery from network/server outages.

## v1.x

- Phases 0–4: interactive configuration, OS hardening, dedicated service
  account, SDRplay API install, SDRangel built from source.
- Fixed three-channel model (a fixed 3-frequency LSB/LSB/USB set).
- Initial `hamhfrx-installer-guide.pdf`.

## Not yet in any released version

- Cloudflare Tunnel automation (phase 7) — deliberately deferred; will
  ask which access model to use rather than assume one.
- baresip / SIP phase (phase 8) — designed in the build manual, not yet
  scripted; needs real Asterisk credentials to be meaningful, and the
  per-channel instance model will need to follow `channels.conf` the
  same way phases 5/6 now do.
- Scheduled local recording + remote transfer (discussed, not designed
  or built).
