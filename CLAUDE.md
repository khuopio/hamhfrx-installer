# Project memory for Claude Code

Read this fully before making changes. It captures hard-won, non-obvious
facts from the original build and debugging sessions — not a restatement
of README.md, which covers usage. See @README.md and @CHANGELOG.md for
additional context; the two bundled PDFs
(`hamhfrx-build-manual.pdf`, `hamhfrx-installer-guide.pdf`) are the full
narrative reference if something here needs more detail than fits.

## What this is

Idempotent shell scripts that build and operate a headless, multichannel
HF SDR receiver (Raspberry Pi 4 + SDRplay RSP2 Pro + SDRangel, built from
source) streaming MP3 to Icecast, with a dormant outbound-only SIP path
designed but not yet scripted (baresip).

## Absolute rules — never violate these

- **Never commit `hamhfrx.conf` or `channels.conf`.** These are the only
  two files that ever contain a real Icecast password, real frequencies,
  or the real hostname. `.gitignore` excludes both — do not remove that
  exclusion, do not add example versions with real-looking values, do
  not paste their contents into a commit message or code comment.
- **Never commit `recordings.conf` or any SSH key material.** Same
  treatment as above — `recordings.conf` names a real remote host and
  path. The recording feature's SSH keypair (`09-recording.sh`) is
  generated on the Pi itself, lives under `/opt/hamhfrx1/.ssh/`, and
  must never be created on, or copied to, a development machine. Never
  print the private key's contents in any log or commit message; the
  public key is the only half ever meant to be displayed or shared.
- **All documentation/example content must use the fictitious worked
  example (3600/7100/4700 kHz, `sdr-station-1` hostname), never real
  production values.** This was deliberately sanitized in v2.2 — don't
  reintroduce real values while "improving" an example. **This rule
  was actually violated once (v2.91), by pasting real production
  frequencies into this file's own "Current known state" section** —
  that section is precisely where this mistake is most tempting, since
  it's meant to track live, real facts. When updating "Current known
  state," describe configuration structurally (channel count, sample
  rate, mode mix, verification results) and never list actual
  frequencies or mountpoints — point to the live `channels.conf` on the
  station instead of ever reproducing its contents here.
- **No script is invoked with an external `sudo` prefix.** Each phase
  script calls `sudo` internally per-command and refuses to run
  (`die`) if launched as root directly. Preserve this pattern in any
  new phase script.
- **`systemctl enable --now` does not restart an already-running/active
  unit — `start` is a no-op against something already active.** Any
  phase script that rewrites a service's script/config and needs that
  change to actually take effect must explicitly `restart`, not just
  `enable --now`. This was a real production bug (v2.8): `06-streaming.sh`
  correctly rewrote every channel's capture-device line, but the
  already-running `ffmpeg` processes never picked up the change because
  nothing restarted them — silently stale for hours, indistinguishable
  from a real ongoing fault. `05-sdrangel-config.sh` avoids this
  correctly by explicitly stopping `sdrangelsrv` earlier in the same
  script, before its own `enable --now` call — that ordering is
  load-bearing, don't remove the early stop without adding an explicit
  restart in its place.

## Non-obvious technical facts (each one cost real debugging time)

1. **`hamsvc` (the service account) must be in both `plugdev` AND
   `audio` groups.** Missing either produces no clear error — SDRangel
   just silently enumerates zero usable audio devices.
2. **`snd-aloop` must load before `sdrangelsrv` starts**, enforced via
   `Requires=systemd-modules-load.service` in the systemd override.
   Same failure mode as above if this ordering breaks.
3. **`sdrangelsrv` requires real-time scheduling**
   (`CPUSchedulingPolicy=rr`, priority 50). Without it, all channels'
   audio FIFOs overflow continuously even with CPU headroom to spare —
   a scheduling-latency problem that looks like a capacity problem.
4. **LSB uses negative `rfBandwidth`/`lowCutoff`; USB uses positive;
   AM uses `AMDemodSettings` with a single symmetric `rfBandwidth`, no
   `lowCutoff` at all.** This is real branching logic in
   `05-sdrangel-config.sh`, not a cosmetic difference. Confirmed against
   a live SDRangel v7.22.7 instance with a real production AM signal
   (previously only verified on paper — see CHANGELOG v2.9).
4a. **AM's `squelch` field must be set explicitly (`-100` in this
    codebase) — SDRangel's own default (`-40` dB) is too aggressive for
    real-world use.** Found in production: a genuinely strong signal
    (`-57` dB `channelPowerDB`, comparable to some of the best SSB
    channels on this station) was gated completely silent because -57
    is weaker than the -40 threshold. SSB channels have no squelch
    gating at all in this codebase — AM's explicit `-100` matches that
    same "always pass audio through" behavior rather than silently
    inheriting a much stricter, untested default.
5. **`POST .../channel` ignores settings embedded in the same request**
   in this SDRangel version — always create the channel bare, then
   `PATCH` its settings in a separate call.
6. **Changing `audioDeviceName` via `PATCH` on an already-open channel
   does not force a reopen.** A fresh channel creation (or full device
   restart, which `05-sdrangel-config.sh` always does on every run) is
   required.
7. **`mktemp` creates files owned by the invoking user, not `hamsvc`.**
   `05-sdrangel-config.sh` copies the generated provisioning script as
   root then `chown`s it — do not "simplify" this back to
   `sudo -u hamsvc cp`, that was the actual v2.1 production bug.
8. **RSP2 Pro firmware uploads on every session open**, not just first
   boot — expect ~20s settle time after `device/run`, and a single
   disconnect/reconnect cycle in `dmesg` at that moment is normal, not
   a fault. A *repeating* cycle is a real USB/cable/power problem.
9. **`StartLimitIntervalSec=0` on every `stream-*` service is
   deliberate**, not an oversight — without it, systemd gives up
   permanently after 5 restarts in 10s, which would turn a real
   multi-hour Icecast outage into a permanently dead stream instead of
   one that self-heals. Confirmed working during a real overnight
   production outage.
10. **Windows-edited files risk CRLF corruption** — `.gitattributes`
    forces LF for `.sh`/`.md`/`.conf`. Don't remove it; development
    happens on Windows, execution always happens on Linux.

## Architecture reference

- `channels.conf` is the single source of truth for receiver channels —
  arbitrary count, any mix of LSB/USB/AM. Never hardcode a channel list
  in a script.
- Services are named after the channel's **mountpoint**, not a
  positional index (`stream-<mountpoint>`), so reordering
  `channels.conf` doesn't orphan a running service.
- `05-sdrangel-config.sh` always stops and rebuilds the entire device
  set on every run — SDRangel's REST API can't diff an existing device
  set against a changed channel count. This is intentional, not a
  missing optimization.
- `06-streaming.sh` actively removes services for mountpoints no longer
  in `channels.conf` — shrinking the channel list cleans up after
  itself.
- `06-streaming.sh` captures from `hw:`, not `dsnoop:` — this remains
  true and load-bearing (see below), but concurrent recording is now
  solved a different way (v3.0), not by giving `dsnoop` another try.
- **Recording concurrency (v3.0): a single `hw:` reader per channel,
  fanned out in software via ffmpeg's `tee` muxer — not a second ALSA
  reader.** For any channel listed in `recordings.conf`,
  `06-streaming.sh` generates a script whose single `hw:`-based ffmpeg
  process writes to *two* outputs simultaneously: the Icecast push
  (unchanged) and a continuously-rotating set of timestamped segment
  files in a RAM-backed `tmpfs` ring buffer
  (`ensure_recording_buffer()` in `lib/common.sh`). `09-recording.sh`
  no longer captures audio at all — it selects buffered segments
  covering a requested time window, concatenates them, and pushes the
  result. This is the "real fan-out design" earlier versions of this
  file said was needed instead of `dsnoop` — it now exists, and was
  tested with real ffmpeg runs (not just review) before shipping:
  - **`-map 0:a` is required for `tee` to work at all.** Without it,
    `tee` fails immediately with "Output file does not contain any
    stream" — confirmed by deliberately omitting it first and watching
    it fail, before adding it.
  - **Segment/`strftime` timing only behaves correctly under
    real-time-paced input.** A synthetic non-real-time test source
    caused multiple segment boundaries to land in the same wall-clock
    second, colliding on the same filename and silently losing data —
    this is a testing artifact, not a production risk, since real
    `hw:` capture from live hardware is inherently real-time-paced.
    Confirmed by re-running the same test with `-re` (forced real-time
    pacing): correct, non-colliding segments every time.
  - **Concatenating buffered segments must re-encode, not stream-copy
    (`-c copy`).** Each segment resets its own timestamps
    (`reset_timestamps=1`), so a straight `-c copy` concat produces the
    same "non-monotonically-increasing dts" warning class that caused
    the v2.7 production incident. Confirmed clean (zero warnings) with
    re-encoding instead — this is why the pull script uses
    `-codec:a libmp3lame -b:a 64k`, not `-c copy`, on the final concat
    step.
  - **One real gap, disclosed rather than hidden: `content_type` inside
    a `tee` output bracket (`[f=mp3:content_type=audio/mpeg]`) could
    only be tested against a local file in the sandbox, not a real
    `icecast://` URL** — `content_type` is an HTTP/Icecast-protocol
    option, not valid for a bare file muxer, so the sandbox test of
    that combination couldn't succeed by construction. It should be
    correct against a real Icecast target (this is documented ffmpeg
    icecast-protocol behavior), but this specific combination was not
    verified end-to-end before release. **Verify the first
    recording-enabled channel especially carefully** — if it doesn't
    connect to Icecast cleanly, try dropping `content_type` from that
    bracket first (confirmed working as a fallback in testing).
  - Buffer sizing is a real RAM cost, not disk — `BUFFER_SIZE_MB` in
    `lib/common.sh` is a hard cap specifically so a misconfiguration
    fails loudly (write errors) rather than risking OOM and taking down
    `sdrangelsrv`. Don't raise retention/size without recalculating the
    real cost (~8 KB/s per channel × retention minutes × 60).
  - The buffer is entirely opt-in, per channel — a channel not listed
    in `recordings.conf` gets the exact same script it's always gotten,
    byte-for-byte. This was a deliberate risk-containment choice: even
    if the `tee` path has an issue, channels not using recording are
    provably unaffected.
- `09-recording.sh` retries any previously-failed transfer (leftover
  `.mp3` files in its capture directory) before starting a new capture
  each time it runs — mirrors the same "retry indefinitely, never
  silently give up" philosophy as the streaming services'
  `StartLimitIntervalSec=0`, just implemented at the script level
  instead of via systemd's restart mechanism, since this is a scheduled
  oneshot rather than a long-running service.
- Everything runs under `/opt/hamhfrx1` (structural convention, not
  meant to change without an explicit, deliberate decision — see
  CHANGELOG v2.2 for the discussion of why this wasn't renamed during
  sanitization).

## Current known state (update this section as things change)

- **Production configuration, confirmed stable as of v2.92**: 6
  simultaneous channels at `SAMPLE_RATE_HZ=4800000` (4.8 MS/s), a mix of
  LSB, USB, and AM modes. The real, currently-deployed `channels.conf`
  is never reproduced here — check the live file on the station itself
  for actual frequencies/mountpoints, never in this document or any
  commit.
- **Verification performed**: zero USB disconnect/reconnect events,
  `vcgencmd get_throttled` = `0x0`, temperature ~58°C, zero systemd
  restarts across all six `stream-*` services, zero
  "backward in time"/non-monotonic-dts errors on any channel over
  multiple checks spanning roughly 15–20 minutes. `sdrangelsrv` itself
  showed a low, non-zero overflow rate (~11/min) with **no** downstream
  corruption reaching any stream — read as acceptable background noise
  at this channel count, not a fault.
- **Not yet done**: a genuine extended soak (30+ minutes continuous) to
  rule out slower-onset issues (thermal creep, memory pressure, buffer
  drift) that a 15–20 minute window can't catch. Treat 6 channels as
  "confirmed likely stable," not "proven under all conditions," until
  that longer run has actually been observed.
- One channel was previously dropped once already this week during
  5-channel testing (unrelated cause — see CHANGELOG v2.7/v2.8, the
  `dsnoop` and `enable --now` bugs, now fixed) before being restored at
  6 channels here. If a channel is ever pulled again for a new
  stability concern, update this section immediately — don't let it
  silently go stale the way the previous placeholder text did.
- **Recording (v3.0): built and unit/integration-tested with synthetic
  audio (real ffmpeg runs, not just code review), but not yet verified
  against a real Icecast server or real ALSA hardware.** See the
  `content_type` caveat in the Architecture reference section above —
  that specific piece needs first-real-use verification. Update this
  note once a real recording-enabled channel has actually been
  confirmed working end-to-end in production.
- baresip/SIP phase: designed in the build manual, not yet scripted.
- Cloudflare Tunnel phase: not yet scripted; intentionally deferred to
  ask which access model fits rather than assuming one.
