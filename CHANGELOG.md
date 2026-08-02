# Changelog

## v2.6 — 2026

**Bugfix: every phase script's terminal output was doubled.** `lib/common.sh`'s
`log()` function wrote each message to the log file *and* echoed it to
the terminal a second time, on top of `step()`/`ok()`/`skip()`/`warn()`/
`die()` already printing their own nicely-formatted line before calling
`log()` — so every single status line appeared twice, once formatted
(`   ok: ...`) and once raw (`OK: ...`). Cosmetic only — it never
affected idempotency, correctness, or what actually got written to
`/var/log/hamhfrx-installer.log` — but genuinely noisy and worth fixing.
`log()` now only writes to the log file. Verified: terminal output shows
each message exactly once, log file still captures everything with
timestamps, unchanged.

No other functional changes in this release.

## v2.5 — 2026

**Bugfix: trailing comments on a data line silently corrupted the last
field.** `channels.conf` and `recordings.conf` only ever safely supported
whole-line comments (`#` as the first character of a line). A comment
placed *after* real data on the same line — e.g.
`3600 | LSB | ch1 | 10  # boosted, weak signal` — was not stripped; it
got silently absorbed into the last field's value (`gain_db` becoming
the literal string `10 # boosted, weak signal`), with no error at parse
time. The failure only surfaced much later and far less clearly, when
that garbage value reached `ffmpeg`'s `-af volume=...` filter at
runtime.

Fixed in both `lib/channels.sh` and `lib/recordings.sh`: comments are
now stripped (everything from the first `#` to end of line) *before*
field splitting, so whole-line and trailing comments both work safely
and uniformly. Verified with a full regression suite: whole-line
comments, indented comments, trailing comments on data lines, blank
lines, comment-only files, and malformed lines all produce the correct
behavior — either a clean parse or a clear, specific `die()` message,
never silent corruption.

Also added: an explicit error for a line with a missing/malformed
frequency (or mountpoint, in `recordings.conf`) field, rather than the
previous silent skip — a genuine typo now fails loudly with the exact
offending line quoted, instead of just vanishing from the loaded
channel list with no explanation.

**Process note, disclosed for transparency:** while fixing this, the
duplicate-mountpoint validation (added earlier, reviewed and tested
correctly at the time) was found to be **missing** from `lib/channels.sh`
in this package lineage — lost when v2.4 was branched from a local
working copy that had drifted from the real, Claude-Code-patched v2.3 on
GitHub. It has been restored and re-verified here. This is exactly the
class of mistake the two-way sync workflow (§ install guide, git
section) exists to catch — always review `git diff` before trusting a
merge, in either direction.

**Documentation:** the install guide now documents `recordings.conf`'s
full format (§7, new section) and the comment syntax for both config
files (§6.5) explicitly, including the "leave the file absent, not
empty" guidance for stations not using the recording feature.

## v2.4 — 2026

**New feature: scheduled recording, pushed securely to a remote system.**

- New `09-recording.sh` phase and `lib/recordings.sh` — captures a
  configurable duration of any channel's audio to MP3 on a systemd-timer
  schedule, then pushes it via `scp` to a remote host and deletes the
  local copy only once delivery is confirmed.
- New `recordings.conf` (gitignored, never committed — see below),
  one line per scheduled recording: mountpoint, `OnCalendar` schedule,
  duration, `user@host` target, remote path. Cross-validated against
  `channels.conf` at load time — a typo'd or removed mountpoint fails
  loudly before any systemd unit is built around it, not silently.
- **Security design, specifically per this release's stated goal —
  keep all key material out of git:**
  - The SSH keypair is generated **on the Pi itself** by
    `09-recording.sh`, never on a development machine, never touched by
    git. Lives under `/opt/hamhfrx1/.ssh/`, structurally outside this
    repository.
  - `.gitignore` extended with `recordings.conf` and defensive
    key/known_hosts filename patterns, as a second layer — not the
    primary protection, which is that the key never exists inside a
    git-tracked directory to begin with.
  - Every `scp`/`ssh` call uses `BatchMode=yes`, so a broken or
    not-yet-authorized key fails immediately with a clear error instead
    of hanging indefinitely waiting for a password prompt that will
    never come.
  - Host key verification is never disabled. `ssh-keyscan` pins each
    remote's host key once, explicitly, during setup —
    `StrictHostKeyChecking` stays at its secure default for every real
    transfer afterward.
- **Resilience**, matching the same philosophy proved out by the
  streaming services' real overnight outage: any failed transfer is
  retried automatically on the *next* scheduled run, before that run's
  new capture even starts — nothing is lost to a transient network or
  remote-server outage, no manual intervention required. Verified with
  mocked `scp` failure/success scenarios before release, not just
  read for correctness.
- `06-streaming.sh` changed to capture from `dsnoop:` instead of `hw:`
  — a necessary prerequisite so a scheduled recording can read a
  channel concurrently with its always-on live stream, which a raw
  `hw:` device (single-reader only) would not have allowed.
- `CLAUDE.md` is now bundled inside the package itself (previously
  delivered standalone) and updated with the new rules above.

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
