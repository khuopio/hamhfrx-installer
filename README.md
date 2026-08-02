# hamhfrx-installer

**v2.9**

Modular, idempotent installer for the multichannel HF SDR receiver build
(Raspberry Pi 4 + SDRplay RSP2 Pro + SDRangel + Icecast streaming).

This package includes two PDFs and a changelog:

- **`hamhfrx-build-manual.pdf`** — the full manual build reference: what
  every step does and why, written for building the station by hand.
  Start here to understand the design.
- **`hamhfrx-installer-guide.pdf`** — how to use the scripts in this
  package to automate that same build. Start here to actually run it.
- **`CHANGELOG.md`** — what changed between versions.

This README is the quick-reference version of the install guide.

## Why phases instead of one script

- **Idempotent** — every phase checks current state before acting, so
  re-running a phase (or the whole thing) after an interruption is safe.
- **Resumable** — if phase 4 (the SDRangel compile) fails or you lose
  your session, you don't redo phases 1–3.
- **Honest about what can't be unattended** — a few steps genuinely need
  a human (browser OAuth for Cloudflare Tunnel, license acceptance in the
  SDRplay installer, physical cable/antenna decisions). Phases that hit
  one of these will say so clearly and pause, rather than silently doing
  something wrong.

## Usage

```bash
git clone <this-repo> hamhfrx-installer   # or download + extract the zip
cd hamhfrx-installer
chmod +x *.sh

./00-configure.sh          # interactive, asks once, writes hamhfrx.conf
./01-hardening.sh          # OS hardening
./02-service-account.sh    # dedicated hamsvc account, /opt layout
./03-sdrplay-api.sh        # SDRplay API — one manual step, see below
./04-sdrangel-build.sh     # build SDRangel from source — see below
```

None of the scripts are invoked with an external `sudo` — each calls
`sudo` internally only for the specific commands that need it, and will
refuse to run if launched as root directly.

Everything logs to `/var/log/hamhfrx-installer.log` in addition to stdout,
so you can review what happened after the fact.

`hamhfrx.conf` is created with `chmod 600` because it holds the Icecast
source password in plain text — treat it like any other secrets file
(don't commit it, don't paste it into chat, etc).

### Phase 3 note — one unavoidable manual step

SDRplay's API installer requires accepting a license interactively and
has no stable long-term download URL, so it can't be fetched
programmatically. The script checks `downloads/` for an installer and
tells you exactly what to grab and where to put it if missing:

```bash
# get the current ARM64/aarch64 .run installer from
# https://www.sdrplay.com/downloads/ and save it into:
#     hamhfrx-installer/downloads/
./03-sdrplay-api.sh
```

### Phase 4 note — the long one, runs detached

The `make` step is 45–90+ minutes on a Pi 4. The script launches it fully
detached (`setsid`/`nohup`/`disown`) so it survives a dropped SSH or
tunnel session. Watch progress with:

```bash
tail -f build/sdrangel-build.log
```

Re-running `./04-sdrangel-build.sh` at any point is safe: it reports
"still building" if the background job is still running, finishes the
install (`make install` + ownership) if it just completed, or reports the
failure clearly (with a pointer to the log) if it didn't succeed.

## Channel configuration — `channels.conf`

Receiver channels are **not** hardcoded and **not** limited to three. Add
as many as you want, in any mix of modes. `./00-configure.sh` walks you
through adding channels interactively, but the result is a plain,
human-editable file — the real source of truth is the file itself, not
the wizard:

```
# freq_khz | mode | mountpoint | gain_db
3600  | LSB | ch1      | 10
7100  | LSB | ch2      |
4700  | USB | ch3      |
6000  | AM  | shortwave|
```

- **`mode`** is `LSB`, `USB`, or `AM`. SSB (LSB/USB) and AM are genuinely
  different underneath — AM has no sideband, so it uses SDRangel's
  `AMDemod` channel type with a single symmetric filter, not the signed
  `rfBandwidth`/`lowCutoff` pair SSB uses. The installer handles this
  automatically per channel based on what you put in this column.
- **`mountpoint`** becomes both the Icecast mount and the name of the
  systemd service for that channel (`stream-<mountpoint>`), so it stays
  tied to a specific channel even if you reorder the file.
- **`gain_db`** is optional, defaults to 0 — apply a boost only to
  channels that actually need it (weak antenna coverage at that
  frequency, etc.), found empirically by listening once the stream is
  live, not guessed in advance.

**To change the channel list at any point:** edit `channels.conf`
directly, then re-run:
```bash
./05-sdrangel-config.sh
./06-streaming.sh
```
Phase 5 always restarts `sdrangelsrv` and reprovisions from a clean
slate when re-run (SDRangel's REST API isn't designed to diff an
existing device set against a changed channel count), sizing the ALSA
loopback device count to match automatically. Phase 6 creates services
for whatever's currently in the file and **removes** the systemd
service/credentials/script for any mountpoint that's no longer present —
so shrinking the channel list cleans up after itself rather than leaving
orphaned services behind.

**Center frequency and sample rate:** the center frequency is computed
automatically as the midpoint between your lowest and highest channel.
Both `00-configure.sh` and `05-sdrangel-config.sh` warn (without
blocking) if the spread between your outermost channels is tight
relative to the configured sample rate — widen `SAMPLE_RATE_HZ` in
`hamhfrx.conf` if you see that warning and want more margin at the
edges.

## Status of this installer

| Phase | Script | Status |
|---|---|---|
| 0 | `00-configure.sh` | done — interactive config collection |
| 1 | `01-hardening.sh` | done — OS hardening (manual §2) |
| 2 | `02-service-account.sh` | done — service account + `/opt` layout (manual §4) |
| 3 | `03-sdrplay-api.sh` | done — SDRplay API install, one manual download step (manual §5.1) |
| 4 | `04-sdrangel-build.sh` | done — build from source, runs detached, resumable (manual §5.3–5.4) |
| 5 | `05-sdrangel-config.sh` | done — ALSA loopback, systemd units, REST provisioning (manual §6) |
| 6 | `06-streaming.sh` | done — ffmpeg + Icecast systemd services, indefinite auto-recovery (manual §7) |
| 7 | `07-cloudflare-tunnel.sh` | not yet built — requires one interactive browser login, several access-method variants possible (see note below) |
| — | `08-baresip.sh` | not yet built — optional, dormant SIP path (manual §10) |

## A note on the Cloudflare Tunnel phase specifically

This one is deliberately left for later, and deliberately **not** assumed
to be a single fixed recipe. The tunnel login step always needs one
interactive browser authorization no matter how it's scripted, but there
are several reasonable ways to structure remote access beyond what this
build originally used (named tunnel + Access application with email OTP):
token-based tunnel creation for a more scriptable first run, WARP-based
private network access instead of a public hostname, or a different
identity provider behind Access. That phase will be designed to ask which
approach you want rather than hardcoding one, since this is the part of
the setup most likely to vary by where and how the station is actually
managed.

## A note on `curl \| bash`

Deliberately not distributed that way. Piping a remote script straight
into a root shell gives you no chance to review what it's about to do.
Download it, read it (or at least skim the phase you're about to run),
then execute it locally.
