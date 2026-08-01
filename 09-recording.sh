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

# --- Per-recording capture+push script and systemd timer/service ---------
mkdir -p /tmp/rec-scripts-staging
CAPTURE_DIR="$INSTALL_ROOT/recording/captures"
sudo -u "$SERVICE_USER" mkdir -p "$CAPTURE_DIR"

for i in "${!REC_MOUNT[@]}"; do
    mount="${REC_MOUNT[$i]}"
    schedule="${REC_SCHEDULE[$i]}"
    duration="${REC_DURATION_MIN[$i]}"
    target="${REC_SSH_TARGET[$i]}"
    remote_path="${REC_REMOTE_PATH[$i]}"
    safe="$(sanitize_name "$mount")"
    unit="record-${safe}"

    # Resolve this mountpoint's position in channels.conf to find its
    # loopback card — same lookup 06-streaming.sh uses.
    pos=0
    for j in "${!CHAN_MOUNT[@]}"; do
        if [ "${CHAN_MOUNT[$j]}" = "$mount" ]; then pos=$((j + 1)); fi
    done
    card="$(loopback_card_name "$pos")"
    capture="dsnoop:CARD=${card},DEV=1"

    step "Recording schedule for $mount -> $target:$remote_path [$unit]"

    SCRIPT_FILE="$INSTALL_ROOT/recording/${unit}.sh"
    cat > "/tmp/rec-scripts-staging/${unit}.sh" <<RECEOF
#!/bin/bash
set -e
SSH_KEY="$SSH_KEY"
TARGET="$target"
REMOTE_PATH="$remote_path"
CAPTURE_DIR="$CAPTURE_DIR"
DURATION_SEC=\$(( $duration * 60 ))
TS=\$(date +%Y%m%d-%H%M%S)
LOCAL_FILE="\$CAPTURE_DIR/${mount}-\${TS}.mp3"

SCP_OPTS="-i \$SSH_KEY -o BatchMode=yes -o ConnectTimeout=15"

# Retry anything left over from a previous failed push before starting
# today's capture — self-healing the same way the live streams do.
for f in "\$CAPTURE_DIR"/${mount}-*.mp3; do
    [ -e "\$f" ] || continue
    if scp \$SCP_OPTS "\$f" "\$TARGET:\$REMOTE_PATH/" 2>/dev/null; then
        rm -f "\$f"
        echo "retried and delivered: \$f"
    fi
done

/usr/bin/ffmpeg -hide_banner -loglevel warning -t "\$DURATION_SEC" \\
  -f alsa -i "$capture" \\
  -ac 1 -channel_layout mono -ar 44100 \\
  -codec:a libmp3lame -b:a 64k \\
  "\$LOCAL_FILE"

if scp \$SCP_OPTS "\$LOCAL_FILE" "\$TARGET:\$REMOTE_PATH/"; then
    rm -f "\$LOCAL_FILE"
    echo "delivered: \$LOCAL_FILE"
else
    echo "transfer failed — \$LOCAL_FILE kept locally, will retry on next scheduled run" >&2
    exit 1
fi
RECEOF
    sudo cp "/tmp/rec-scripts-staging/${unit}.sh" "$SCRIPT_FILE"
    sudo chown "$SERVICE_USER:$SERVICE_USER" "$SCRIPT_FILE"
    sudo chmod +x "$SCRIPT_FILE"
    ok "capture+push script written"

    sudo tee "/etc/systemd/system/${unit}.service" >/dev/null <<EOF
[Unit]
Description=Scheduled recording - ${mount}
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
Description=Timer for scheduled recording - ${mount}

[Timer]
OnCalendar=${schedule}
Persistent=true

[Install]
WantedBy=timers.target
EOF
    ok "systemd service + timer written (OnCalendar: ${schedule})"
done
rm -rf /tmp/rec-scripts-staging

sudo systemctl daemon-reload
for i in "${!REC_MOUNT[@]}"; do
    safe="$(sanitize_name "${REC_MOUNT[$i]}")"
    sudo systemctl enable --now "record-${safe}.timer"
done

echo
echo "=== Phase 9 complete ==="
echo "List scheduled recordings and next run times with:"
echo "    systemctl list-timers 'record-*'"
echo "Test one immediately without waiting for its schedule:"
echo "    sudo systemctl start record-<mountpoint>.service"
echo "    sudo journalctl -u record-<mountpoint>.service -f"
