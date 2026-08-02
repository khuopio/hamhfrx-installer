#!/bin/bash
# Phase 9 — scheduled local recording + secure push to a remote system.
#
# SECURITY DESIGN — read before modifying:
#
#   - The SSH keypair is generated HERE, on the Pi, by this script. It is
#     never created on a development machine, never passes through git,
#     and is not part of this repository in any form.
#   - Private key lives at /opt/hamhfrx1/.ssh/id_ed25519, owned by
#     hamsvc, mode 600. It is structurally outside any git-tracked
#     directory (this repo lives elsewhere entirely) — but .gitignore
#     also excludes common key filename patterns as defense in depth,
#     in case that ever changes.
#   - recordings.conf names a real remote host/path and is therefore
#     treated exactly like hamhfrx.conf/channels.conf: gitignored, never
#     committed.
#   - scp/ssh calls always use BatchMode=yes — if key auth fails for any
#     reason, the connection fails immediately with a clear error rather
#     than hanging indefinitely waiting for a password that will never
#     come (which would leave a captured recording stuck and the next
#     scheduled run piling up behind it).
#   - Host key verification is NOT disabled. ssh-keyscan populates
#     known_hosts once, explicitly, during setup — StrictHostKeyChecking
#     stays at its secure default for every actual transfer afterward.
#
# Idempotent: safe to re-run after editing recordings.conf.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/channels.sh"
source "$SCRIPT_DIR/lib/recordings.sh"
[ -f "$SCRIPT_DIR/hamhfrx.conf" ] || die "Run ./00-configure.sh first."
source "$SCRIPT_DIR/hamhfrx.conf"

[ "$EUID" -eq 0 ] && die "Run as your normal user (this script uses sudo internally where needed)."

RECORDINGS_FILE="$SCRIPT_DIR/recordings.conf"
if [ ! -f "$RECORDINGS_FILE" ]; then
    cat <<EOF

   $RECORDINGS_FILE not found.

   Create it (NOT tracked by git — see .gitignore) with one line per
   scheduled recording:

       mountpoint | OnCalendar_expr | duration_min | user@host | remote_path

   Example — daily at 14:00, 60 minutes, channel 'ch1':

       ch1 | *-*-* 14:00:00 | 60 | archiveuser@backup.example.org | /data/hf-recordings

   Then re-run: ./09-recording.sh

EOF
    exit 1
fi

load_channels "$CHANNELS_FILE"
load_recordings "$RECORDINGS_FILE"
validate_recordings_against_channels
step "Loaded ${#REC_MOUNT[@]} scheduled recording(s), validated against $CHANNELS_FILE"

# Every scheduled recording's requested duration must fit within the ring
# buffer's actual retention window — a request for more than what's ever
# buffered would silently return a shorter recording than expected.
for i in "${!REC_MOUNT[@]}"; do
    if [ "${REC_DURATION_MIN[$i]}" -gt "$BUFFER_RETENTION_MIN" ]; then
        die "Recording for '${REC_MOUNT[$i]}' requests ${REC_DURATION_MIN[$i]} minutes, but the ring buffer only retains ${BUFFER_RETENTION_MIN} minutes (set in lib/common.sh). Either shorten the request or increase BUFFER_RETENTION_MIN and BUFFER_SIZE_MB together, deliberately."
    fi
done

step "Recording ring buffer (RAM-backed, ${BUFFER_RETENTION_MIN}-minute retention)"
ensure_recording_buffer

# --- Dedicated SSH keypair, generated here, never elsewhere ---------------
SSH_DIR="$INSTALL_ROOT/.ssh"
SSH_KEY="$SSH_DIR/id_ed25519"

step "SSH keypair for recording transfers"
sudo -u "$SERVICE_USER" mkdir -p "$SSH_DIR"
sudo chmod 700 "$SSH_DIR"

if [ ! -f "$SSH_KEY" ]; then
    sudo -u "$SERVICE_USER" ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" \
        -C "hamsvc@$(hostname)-recording-push"
    ok "generated new keypair at $SSH_KEY"
else
    skip "keypair already exists at $SSH_KEY"
fi
sudo chmod 600 "$SSH_KEY"
sudo chmod 644 "$SSH_KEY.pub"

echo
echo "   ---------------------------------------------------------------"
echo "   Public key (safe to share — copy this to each remote system's"
echo "   ~/.ssh/authorized_keys for the receiving account):"
echo
sudo cat "$SSH_KEY.pub"
echo "   ---------------------------------------------------------------"
echo "   The PRIVATE key never leaves this directory and is never shown."
echo

if ! confirm "Have you added the public key above to every remote system's authorized_keys?"; then
    echo "   Add it now, then re-run ./09-recording.sh to continue with"
    echo "   known_hosts setup and the recording schedules themselves."
    exit 0
fi

# --- Pin host keys once, explicitly — never disable checking later -------
step "Pinning remote host keys (known_hosts)"
KNOWN_HOSTS="$SSH_DIR/known_hosts"
for target in "${REC_SSH_TARGET[@]}"; do
    host="${target#*@}"
    if sudo -u "$SERVICE_USER" ssh-keygen -F "$host" -f "$KNOWN_HOSTS" >/dev/null 2>&1; then
        skip "host key already pinned for $host"
    else
        sudo -u "$SERVICE_USER" bash -c "ssh-keyscan -H '$host' >> '$KNOWN_HOSTS'" \
            && ok "pinned host key for $host" \
            || die "could not reach $host to fetch its host key — check the hostname/network before continuing"
    fi
done
sudo chmod 644 "$KNOWN_HOSTS"

# --- Per-recording pull-from-buffer + push script and systemd timer -------
# This does NOT capture audio itself — 06-streaming.sh's tee output has
# already been continuously writing this channel's audio into the ring
# buffer (if this mountpoint is listed here in recordings.conf). This
# script's only job is: select the buffered segments covering the
# requested window, stitch them into one file, and push it.
mkdir -p /tmp/rec-scripts-staging

for i in "${!REC_MOUNT[@]}"; do
    mount="${REC_MOUNT[$i]}"
    schedule="${REC_SCHEDULE[$i]}"
    duration="${REC_DURATION_MIN[$i]}"
    target="${REC_SSH_TARGET[$i]}"
    remote_path="${REC_REMOTE_PATH[$i]}"
    safe="$(sanitize_name "$mount")"
    unit="record-${safe}"

    step "Recording schedule for $mount -> $target:$remote_path [$unit]"

    SCRIPT_FILE="$INSTALL_ROOT/recording/${unit}.sh"
    cat > "/tmp/rec-scripts-staging/${unit}.sh" <<RECEOF
#!/bin/bash
set -e
SSH_KEY="$SSH_KEY"
TARGET="$target"
REMOTE_PATH="$remote_path"
BUFFER_DIR="$BUFFER_DIR"
PULL_DIR="\$BUFFER_DIR/pulls"
MOUNT="$mount"
DURATION_MIN=$duration

mkdir -p "\$PULL_DIR"
SCP_OPTS="-i \$SSH_KEY -o BatchMode=yes -o ConnectTimeout=15"

# Retry any previously-failed pushes before doing today's pull — same
# self-healing philosophy as the live streams' StartLimitIntervalSec=0,
# just implemented at the script level since this is a scheduled oneshot.
for f in "\$PULL_DIR"/\${MOUNT}-*.mp3; do
    [ -e "\$f" ] || continue
    if scp \$SCP_OPTS "\$f" "\$TARGET:\$REMOTE_PATH/" 2>/dev/null; then
        rm -f "\$f"
        echo "retried and delivered: \$f"
    fi
done

TS=\$(date +%Y%m%d-%H%M%S)
CONCAT_LIST="\$PULL_DIR/.concat-\${MOUNT}-\${TS}.txt"
PULLED_FILE="\$PULL_DIR/\${MOUNT}-\${TS}.mp3"

> "\$CONCAT_LIST"
find "\$BUFFER_DIR" -maxdepth 1 -name "\${MOUNT}-*.mp3" -newermt "-\${DURATION_MIN} minutes" | sort | while IFS= read -r f; do
    echo "file '\$f'" >> "\$CONCAT_LIST"
done

if [ ! -s "\$CONCAT_LIST" ]; then
    echo "no buffered segments found for \$MOUNT in the last \${DURATION_MIN} minutes — nothing to pull" >&2
    rm -f "\$CONCAT_LIST"
    exit 0
fi

# Re-encode, not stream-copy — each buffered segment resets its own
# timestamps, so a straight -c copy concat produces non-monotonic dts
# warnings. Confirmed clean with re-encoding during testing before this
# shipped; do not "optimize" this back to -c copy.
ffmpeg -hide_banner -loglevel warning -f concat -safe 0 -i "\$CONCAT_LIST" \\
  -codec:a libmp3lame -b:a 64k "\$PULLED_FILE"
rm -f "\$CONCAT_LIST"

if scp \$SCP_OPTS "\$PULLED_FILE" "\$TARGET:\$REMOTE_PATH/"; then
    rm -f "\$PULLED_FILE"
    echo "delivered: \$PULLED_FILE"
else
    echo "transfer failed — \$PULLED_FILE kept locally, will retry on next run" >&2
    exit 1
fi
RECEOF
    sudo cp "/tmp/rec-scripts-staging/${unit}.sh" "$SCRIPT_FILE"
    sudo chown "$SERVICE_USER:$SERVICE_USER" "$SCRIPT_FILE"
    sudo chmod +x "$SCRIPT_FILE"
    ok "pull+push script written"

    sudo tee "/etc/systemd/system/${unit}.service" >/dev/null <<EOF
[Unit]
Description=Scheduled recording pull - ${mount}
After=network-online.target sdrangelsrv.service
Wants=network-online.target
Requires=sdrangelsrv.service

[Service]
Type=oneshot
User=$SERVICE_USER
ExecStart=$SCRIPT_FILE
EOF

    sudo tee "/etc/systemd/system/${unit}.timer" >/dev/null <<EOF
[Unit]
Description=Timer for scheduled recording pull - ${mount}

[Timer]
OnCalendar=${schedule}
Persistent=true

[Install]
WantedBy=timers.target
EOF
    ok "systemd service + timer written (OnCalendar: ${schedule})"
done
rm -rf /tmp/rec-scripts-staging

# --- Retention cleanup: delete buffer segments older than the window ------
step "Buffer retention cleanup (deletes segments older than ${BUFFER_RETENTION_MIN} minutes, every 5 minutes)"
CLEANUP_SCRIPT="$INSTALL_ROOT/bin/buffer-cleanup.sh"
cat > /tmp/buffer-cleanup.sh <<CLEANUPEOF
#!/bin/bash
find "$BUFFER_DIR" -maxdepth 1 -name '*.mp3' -mmin +${BUFFER_RETENTION_MIN} -delete
CLEANUPEOF
sudo cp /tmp/buffer-cleanup.sh "$CLEANUP_SCRIPT"
rm -f /tmp/buffer-cleanup.sh
sudo chown "$SERVICE_USER:$SERVICE_USER" "$CLEANUP_SCRIPT"
sudo chmod +x "$CLEANUP_SCRIPT"

sudo tee /etc/systemd/system/buffer-cleanup.service >/dev/null <<EOF
[Unit]
Description=Delete recording ring buffer segments past retention window

[Service]
Type=oneshot
User=$SERVICE_USER
ExecStart=$CLEANUP_SCRIPT
EOF

sudo tee /etc/systemd/system/buffer-cleanup.timer >/dev/null <<'EOF'
[Unit]
Description=Timer for recording ring buffer retention cleanup

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF
ok "buffer retention cleanup timer written (runs every 5 minutes)"

# --- On-demand pull, for ad-hoc "grab the last N minutes right now" -------
step "On-demand pull script (not tied to any schedule)"
ONDEMAND_SCRIPT="$INSTALL_ROOT/bin/pull-recording.sh"
cat > /tmp/pull-recording.sh <<PULLEOF
#!/bin/bash
# Usage: pull-recording.sh <mountpoint> <minutes> <user@host> <remote_path>
# Grabs whatever is currently in the ring buffer for the requested
# channel and window, right now — independent of any recordings.conf
# schedule. Useful for "something just happened, grab the last hour."
set -e
MOUNT="\$1"; MINUTES="\$2"; TARGET="\$3"; REMOTE_PATH="\$4"
[ -z "\$MOUNT" ] || [ -z "\$MINUTES" ] || [ -z "\$TARGET" ] || [ -z "\$REMOTE_PATH" ] && {
    echo "Usage: \$0 <mountpoint> <minutes> <user@host> <remote_path>" >&2
    exit 1
}
BUFFER_DIR="$BUFFER_DIR"
SSH_KEY="$SSH_KEY"
PULL_DIR="\$BUFFER_DIR/pulls"
mkdir -p "\$PULL_DIR"
SCP_OPTS="-i \$SSH_KEY -o BatchMode=yes -o ConnectTimeout=15"

TS=\$(date +%Y%m%d-%H%M%S)
CONCAT_LIST="\$PULL_DIR/.concat-\${MOUNT}-\${TS}.txt"
PULLED_FILE="\$PULL_DIR/\${MOUNT}-\${TS}.mp3"

> "\$CONCAT_LIST"
find "\$BUFFER_DIR" -maxdepth 1 -name "\${MOUNT}-*.mp3" -newermt "-\${MINUTES} minutes" | sort | while IFS= read -r f; do
    echo "file '\$f'" >> "\$CONCAT_LIST"
done

if [ ! -s "\$CONCAT_LIST" ]; then
    echo "no buffered segments found for \$MOUNT in the last \${MINUTES} minutes" >&2
    rm -f "\$CONCAT_LIST"
    exit 1
fi

ffmpeg -hide_banner -loglevel warning -f concat -safe 0 -i "\$CONCAT_LIST" \\
  -codec:a libmp3lame -b:a 64k "\$PULLED_FILE"
rm -f "\$CONCAT_LIST"

if scp \$SCP_OPTS "\$PULLED_FILE" "\$TARGET:\$REMOTE_PATH/"; then
    rm -f "\$PULLED_FILE"
    echo "delivered: \$PULLED_FILE"
else
    echo "transfer failed — \$PULLED_FILE kept at \$PULLED_FILE, retry manually" >&2
    exit 1
fi
PULLEOF
sudo cp /tmp/pull-recording.sh "$ONDEMAND_SCRIPT"
rm -f /tmp/pull-recording.sh
sudo chown "$SERVICE_USER:$SERVICE_USER" "$ONDEMAND_SCRIPT"
sudo chmod +x "$ONDEMAND_SCRIPT"
ok "on-demand pull script written: $ONDEMAND_SCRIPT"

sudo systemctl daemon-reload
for i in "${!REC_MOUNT[@]}"; do
    safe="$(sanitize_name "${REC_MOUNT[$i]}")"
    # Same fix as 06-streaming.sh (v2.8): enable --now is a no-op on an
    # already-active timer, so a changed OnCalendar schedule wouldn't
    # take effect until an explicit restart.
    sudo systemctl enable "record-${safe}.timer"
    sudo systemctl restart "record-${safe}.timer"
done
sudo systemctl enable buffer-cleanup.timer
sudo systemctl restart buffer-cleanup.timer

echo
echo "=== Phase 9 complete ==="
echo "IMPORTANT — re-run ./06-streaming.sh now if you haven't already since"
echo "editing recordings.conf: only channels listed here get the ring"
echo "buffer, and 06-streaming.sh is what actually feeds it."
echo
echo "List scheduled recordings and next run times with:"
echo "    systemctl list-timers 'record-*' 'buffer-cleanup*'"
echo "Test one immediately without waiting for its schedule:"
echo "    sudo systemctl start record-<mountpoint>.service"
echo "    sudo journalctl -u record-<mountpoint>.service -f"
echo "Grab an ad-hoc window any time, outside any schedule:"
echo "    sudo -u $SERVICE_USER $ONDEMAND_SCRIPT <mountpoint> <minutes> <user@host> <remote_path>"
