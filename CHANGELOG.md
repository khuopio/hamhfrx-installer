# Changelog

## v3.1 — 2026

**Documentation fix: `recordings.conf` documentation was stale
(describing v2.x's live-capture semantics after v3.0 changed to a
pull-from-buffer model), and there was no template file to start from.**

- `hamhfrx-installer-guide.pdf` §5.7 and §7 rewritten to describe the
  actual v3.0 architecture: `06-streaming.sh` feeds the ring buffer,
  `09-recording.sh` pulls from it — not a live capture. `duration_min`
  renamed `pull_minutes` in the documentation to make this unambiguous
  (the file format itself is unchanged, this is a naming/description
  fix, not a breaking change).
- Added `recordings.conf.example` — a fully commented template with no
  real data (safe to commit, unlike the real `recordings.conf`, which
  stays gitignored). Verified it parses correctly through the real
  parser once uncommented, not just reviewed for correctness.
- `09-recording.sh`'s "file not found" message now points to the
  template and suggests `cp recordings.conf.example recordings.conf`
  as the starting step, instead of asking the user to write the format
  from memory.

No script logic changes beyond the updated message text.

## v3.0 — 2026

**Recording feature redesigned: RAM-backed rolling buffer instead of
live on-demand capture, replacing the `dsnoop` approach abandoned in
v2.7.**

Previous design (v2.4–v2.9): a scheduled recording ran its own live
`dsnoop`-based ALSA capture, competing with the always-on stream for the
same device. `dsnoop` caused a real production regression (v2.7) and was
reverted to `hw:` for streaming, leaving recording unable to run
concurrently with a live channel at all.

**New design:** a single `hw:` reader per channel (unchanged, the same
proven-stable capture) now optionally fans out in software via ffmpeg's
`tee` muxer — one branch to Icecast exactly as before, a second branch
writing continuously-rotating timestamped segments into a RAM-backed
`tmpfs` ring buffer. `09-recording.sh` no longer captures audio at all;
it selects the buffered segments covering a requested window,
concatenates them, and pushes the result. This eliminates the
multi-reader ALSA problem entirely rather than trying to make `dsnoop`
more robust.

This also adds a genuinely new capability beyond what was there before:
an **on-demand pull script** (`pull-recording.sh`) for grabbing "the
last N minutes, right now" outside any schedule — not just fixed,
pre-scheduled recording windows.

**Design constraints, deliberate:**
- Buffer retention is 60 minutes by default (`BUFFER_RETENTION_MIN` in
  `lib/common.sh`), sized specifically to the actual stated need (light,
  occasional use) rather than defaulting to something larger — RAM
  usage is a real, hard-capped cost (`BUFFER_SIZE_MB`), not disk, and
  oversizing it risks system-wide OOM, a worse failure mode than the SD
  card wear it's replacing.
- `recordings.conf` entries requesting more than the buffer's retention
  window now fail loudly at setup time, rather than silently returning
  a shorter recording than expected.
- The `tee` output is entirely opt-in, per channel — only channels
  listed in `recordings.conf` get it; every other channel's script is
  byte-for-byte unchanged from before this release.

**Testing performed before release** (real ffmpeg runs against synthetic
audio, not just code review — see CLAUDE.md for full detail): confirmed
`tee` requires explicit `-map 0:a`; confirmed segment/`strftime` timing
only behaves correctly under real-time-paced input (a synthetic
non-real-time test source caused a filename collision that doesn't occur
with real live `hw:` capture); confirmed concatenating buffered segments
must re-encode rather than stream-copy, to avoid the same class of dts
warning that caused the v2.7 incident; confirmed the full pull-and-push
flow including failure/retry behavior end-to-end; confirmed the
retention cleanup logic against files of varying ages.

**One gap, disclosed rather than hidden:** the `content_type` option
inside the `tee` output bracket for the Icecast branch could only be
tested against a local file in this sandbox, not a real `icecast://`
URL — `content_type` is an HTTP/Icecast-protocol option and isn't valid
against a bare file muxer, so that specific combination could not be
verified end-to-end before release. It should be correct (documented
ffmpeg behavior), but the first recording-enabled channel deployed
should be verified carefully; a tested fallback (dropping `content_type`
from that bracket) is documented in `CLAUDE.md` if needed.

**Not yet updated in this release:** `hamhfrx-installer-guide.pdf`'s
recordings.conf documentation (§7) still describes the previous
live-capture semantics; the field format is unchanged but the
description of what `duration_min` actually does should be revised to
reflect the new pull-from-buffer behavior. Flagged here rather than left
silently stale.

## v2.92 — 2026

**Documentation-only update: `CLAUDE.md`'s "Current known state" section
updated with the actual confirmed production configuration — and a real
sanitization mistake caught and fixed in the same pass.**

Replaces the generic "under active tuning" placeholder with the real,
verified result of this week's stress testing: 6 simultaneous channels,
a mix of LSB/USB/AM modes, confirmed stable at `SAMPLE_RATE_HZ=4800000`,
following the resolution of the `dsnoop` regression (v2.7), the
`enable --now` stale-process bug (v2.8), and the AM squelch default
(v2.9). Verification performed and honestly documented as such: zero
USB events, zero throttling, stable temperature, zero stream restarts,
zero downstream timestamp corruption across roughly 15–20 minutes of
checks — explicitly noted as **not yet** including a genuine 30+ minute
extended soak, so the state is recorded as "confirmed likely stable,"
not overclaimed as fully proven.

**Process note:** an earlier pass at this same update (briefly built as
v2.91, never actually shipped) violated this project's own frequency-
sanitization rule by listing the real production frequencies directly
in `CLAUDE.md`. Caught before release, fixed here, and the underlying
rule in `CLAUDE.md` itself strengthened with an explicit warning about
this exact failure mode — the "Current known state" section is
precisely where this mistake is most tempting, since it's meant to
track live, real facts, which makes it easy to forget the same
sanitization discipline applied everywhere else in this project. Also
found and fixed the same leak in this file's own v2.9 entry (below),
which had named a real frequency while documenting the AM squelch fix.

No script changes in this release.

## v2.9 — 2026

**Bugfix: AM channels were silently gated by an overly aggressive
default squelch threshold.**

The first AM channel actually deployed to production
appeared silent to listeners despite the full audio pipeline being
confirmed healthy (v2.7/v2.8). Root cause: `05-sdrangel-config.sh` never
explicitly set `AMDemodSettings.squelch`, so it silently inherited
SDRangel's own default of `-40` dB. The real signal measured
`channelPowerDB: -57` dB — objectively strong (comparable to some of
this station's best SSB channels) but weaker than the -40 threshold, so
squelch stayed permanently closed and no audio ever passed through, even
though every other layer (SDRangel capture, ALSA loopback, ffmpeg
encode, Icecast push) was working correctly.

**Fixed:** AM channels now explicitly set `squelch: -100`, well below
any realistic noise floor — matching the "always pass audio through"
behavior SSB channels have had by default the whole time (they carry no
squelch gating at all in this codebase).

This is also the first time AM's field names/structure have been
verified against a real production signal, not just documentation —
`CLAUDE.md` updated accordingly.

**If you already have an AM channel deployed on an earlier version**,
this fix requires re-running `./05-sdrangel-config.sh` (which
reprovisions the full device set) to take effect — it is not picked up
by `./06-streaming.sh` alone, since squelch is an SDRangel device/channel
setting, not part of the streaming layer.

## v2.8 — 2026

**Production bug found and fixed: config/script changes silently didn't
take effect on already-running channels.**

While chasing what looked like a per-channel audio problem (see v2.7),
the actual mechanism turned out to be broader and more fundamental:
`06-streaming.sh` used `systemctl enable --now "$unit"` to bring each
channel's stream service up — but `start` (which `--now` invokes) is a
no-op against a service that's already active. Every time this script
was re-run against already-running channels — including the v2.7
`dsnoop`→`hw:` fix itself — the script *files* on disk were rewritten
correctly, but the *already-running* `ffmpeg` processes kept executing
with whatever command line they'd originally loaded, completely unaware
anything had changed. This meant the v2.7 fix appeared not to work when
tested, purely because the fix was never actually applied to the live
processes — confirmed directly by comparing the deployed script content
(correct) against the running process behavior (still exhibiting the
old symptom) before finding the real cause.

**Fixed:** `06-streaming.sh` and `09-recording.sh`'s timer setup now
explicitly `enable` then `restart` every unit, rather than relying on
`enable --now`. Checked every other `enable --now` call in the codebase
for the same risk: `01-hardening.sh`'s fail2ban already has an explicit
follow-up restart (safe), and `05-sdrangel-config.sh`'s `sdrangelsrv`
call is preceded by an explicit `stop` earlier in the same script,
guaranteeing the service is inactive by the time `enable --now` runs
(also safe, but this ordering is now called out explicitly in
`CLAUDE.md` as load-bearing — don't refactor it away without adding an
equivalent explicit restart).

**Immediate production impact:** if you hit the v2.7 symptom persisting
after updating, the fix is a one-time manual restart of the affected
services (`sudo systemctl restart stream-<mountpoint>`) — this release
prevents it from recurring silently on future config changes.

## v2.7 — 2026

**Production regression found and reverted: `dsnoop` capture caused
stream instability across every channel.**

v2.4 switched `06-streaming.sh`'s capture device from `hw:` to `dsnoop:`
so a scheduled recording could read a channel concurrently with its
live stream. This looked correct in isolated testing at the time, but
once actually deployed to production it produced continuous
`Queue input is backward in time` / non-monotonically-increasing-dts
errors from `ffmpeg` — initially suspected to be AM-specific (a new AM
channel was added the same session), but confirmed by direct testing to
affect **every** channel, including SSB channels that had run reliably
for days beforehand. Root cause confirmed by exact timestamp correlation
between the regression's onset and the moment `06-streaming.sh` was
re-run with the `dsnoop` change live.

**Fix:** reverted `06-streaming.sh` to `hw:` (exclusive access) — the
configuration proven stable over multiple days of real production
operation, including surviving a genuine multi-hour Icecast outage
cleanly.

**Known consequence, not yet resolved:** recording and streaming can no
longer run concurrently on the same channel — `09-recording.sh`'s
`dsnoop`-based capture will fail to acquire a device already held
exclusively by a live `hw:` stream. Since the recording feature has
never actually been used in production, this is an acceptable trade
for restoring stream reliability now. A real fix requires a proper
single-reader fan-out design (e.g., one `hw:` process per channel that
itself tees to both the Icecast push and an on-demand local recording
sink) rather than relying on ALSA's `dsnoop` layer for real-time
reliability — flagged as follow-up work in `CLAUDE.md`.

**Process lesson, worth being direct about:** this shipped in v2.4
without being tested against sustained real production load — only
syntax and mocked control-flow were verified before release. That gap
is exactly what let a real regression reach production. Any future
change to a capture/audio-path detail should be soak-tested against a
running channel before being considered safe, not just reviewed for
correctness on paper.

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
