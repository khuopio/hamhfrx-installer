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
  reintroduce real values while "improving" an example.
- **No script is invoked with an external `sudo` prefix.** Each phase
  script calls `sudo` internally per-command and refuses to run
  (`die`) if launched as root directly. Preserve this pattern in any
  new phase script.

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
   `05-sdrangel-config.sh`, not a cosmetic difference.
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
- `06-streaming.sh` captures from `hw:`, not `dsnoop:`. **This was
  changed back and forth once already — read this before touching it
  again.** v2.4 switched to `dsnoop:` so a scheduled recording could
  share the capture device with the always-on stream. Once actually
  deployed to production, `dsnoop` caused real, confirmed instability
  ("Queue input is backward in time" / non-monotonic dts, across every
  channel, not just the new one being tested at the time — confirmed by
  exact timestamp correlation between the regression and when `dsnoop`
  went live). Reverted to `hw:` in v2.7. **Consequence:** recording and
  streaming cannot currently run concurrently on the same channel —
  `09-recording.sh`'s `dsnoop` read will fail to acquire a device
  already held exclusively by a live `hw:` stream. This needs a real
  fan-out design (e.g. a single `hw:` reader per channel that itself
  tees to both the Icecast push and an on-demand local recording sink)
  before recording can be used while that channel is actively streamed.
  Do not "fix" this by switching back to `dsnoop` without first proving
  stability under real, sustained production load — a quiet workbench
  test is not sufficient evidence, as this exact regression
  demonstrated.
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

- Production channel count/sample-rate: under active tuning as of the
  last session — see CHANGELOG and git log for the most recent change,
  don't assume the shipped worked-example values reflect what's
  actually running.
- baresip/SIP phase: designed in the build manual, not yet scripted.
- Cloudflare Tunnel phase: not yet scripted; intentionally deferred to
  ask which access model fits rather than assuming one.
