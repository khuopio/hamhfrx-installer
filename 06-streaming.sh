#!/bin/bash
# Phase 6 — MP3 encode + push to Icecast, one systemd service per channel
# (named after its mountpoint, not a fixed index, so reordering channels
# in channels.conf doesn't orphan a service). Indefinite automatic
# recovery from network/server interruptions. Idempotent, and cleans up
# services for any mountpoint no longer present in channels.conf.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/channels.sh"
[ -f "$SCRIPT_DIR/hamhfrx.conf" ] || die "Run ./00-configure.sh first."
source "$SCRIPT_DIR/hamhfrx.conf"

[ "$EUID" -eq 0 ] && die "Run as your normal user (this script uses sudo internally where needed)."
systemctl is-active --quiet sdrangelsrv || die "sdrangelsrv is not running. Run ./05-sdrangel-config.sh first."

if [ -z "$ICECAST_HOST" ] || [ -z "$ICECAST_PASSWORD" ]; then
    cat <<EOF

   Icecast host/password not set in hamhfrx.conf.
   Edit it by hand (chmod 600, only your user can read it):
       nano $SCRIPT_DIR/hamhfrx.conf
   Set ICECAST_HOST, ICECAST_PORT, ICECAST_PASSWORD, then re-run:
       ./06-streaming.sh

EOF
    exit 1
fi

step "Installing ffmpeg"
run_once "dpkg -l ffmpeg 2>/dev/null | grep -q ^ii" sudo apt-get -y -qq install ffmpeg
ffmpeg -codecs 2>/dev/null | grep -q libmp3lame || die "libmp3lame encoder not available in this ffmpeg build."
ok "ffmpeg with libmp3lame confirmed"

load_channels "$CHANNELS_FILE"
N="${#CHAN_FREQ_KHZ[@]}"
step "Loaded $N channel(s) from $CHANNELS_FILE"

sanitize() { printf '%s' "$1" | tr -c 'A-Za-z0-9_' '-'; }

DESIRED_UNITS=()
for i in "${!CHAN_FREQ_KHZ[@]}"; do
    pos=$((i + 1))
    freq="${CHAN_FREQ_KHZ[$i]}"
    mode="${CHAN_MODE[$i]}"
    mount="${CHAN_MOUNT[$i]}"
    gain="${CHAN_GAIN_DB[$i]}"
    card="$(loopback_card_name "$pos")"
    # hw:, not dsnoop: — reverted in v2.7. dsnoop was adopted in v2.4 to
    # let a scheduled recording (09-recording.sh) share this capture
    # device with the always-on stream, but caused real production
    # instability once actually deployed: "Queue input is backward in
    # time" / non-monotonic dts errors across EVERY channel, confirmed
    # by exact timestamp correlation with when dsnoop went live — not
    # specific to any one channel or mode. hw: is what ran reliably for
    # days beforehand. Since recording was never actually in concurrent
    # use, this reverts to the known-stable configuration.
    #
    # CONSEQUENCE: 09-recording.sh's dsnoop-based capture will now fail
    # to acquire the device whenever a live stream already holds it via
    # hw: (exclusive). Recording and streaming cannot run concurrently
    # on the same channel until a proper fan-out is built — see
    # CLAUDE.md and CHANGELOG v2.7 for the real fix this needs.
    capture="hw:CARD=${card},DEV=1"
    safe="$(sanitize "$mount")"
    unit="stream-${safe}"
    DESIRED_UNITS+=("$unit")

    step "Channel $pos ($freq kHz $mode) -> mountpoint $mount [$unit]"

    ENV_FILE="$INSTALL_ROOT/streaming/icecast-${safe}.env"
    sudo -u "$SERVICE_USER" tee "$ENV_FILE" >/dev/null <<EOF
ICECAST_URL=icecast://source:${ICECAST_PASSWORD}@${ICECAST_HOST}:${ICECAST_PORT}/${mount}
EOF
    sudo chmod 600 "$ENV_FILE"

    GAIN_FILTER=""
    if [ "$gain" != "0" ]; then
        GAIN_FILTER="-af volume=${gain}dB "
    fi

    SCRIPT_FILE="$INSTALL_ROOT/streaming/${unit}.sh"
    sudo -u "$SERVICE_USER" tee "$SCRIPT_FILE" >/dev/null <<SCRIPTINNEREOF
#!/bin/bash
set -e
source $ENV_FILE

exec stdbuf -oL -eL /usr/bin/ffmpeg -hide_banner -loglevel warning \\
  -f alsa -i $capture \\
  ${GAIN_FILTER}-ac 1 -channel_layout mono -ar 44100 \\
  -codec:a libmp3lame -b:a 64k -content_type audio/mpeg \\
  -f mp3 "\$ICECAST_URL" 2>&1 | sed -u -E 's#(source:)[^@]*(@)#\\1REDACTED\\2#'
SCRIPTINNEREOF
    sudo chmod +x "$SCRIPT_FILE"
    ok "credentials + script written (gain: ${gain} dB)"

    sudo tee "/etc/systemd/system/${unit}.service" >/dev/null <<EOF
[Unit]
Description=MP3 Icecast stream - ${freq} kHz ${mode} -> ${mount}
After=network-online.target sdrangelsrv.service
Wants=network-online.target
Requires=sdrangelsrv.service
StartLimitIntervalSec=0

[Service]
Type=simple
User=$SERVICE_USER
ExecStart=$SCRIPT_FILE
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    ok "systemd unit written (StartLimitIntervalSec=0 — retries forever)"
done

sudo systemctl daemon-reload
for unit in "${DESIRED_UNITS[@]}"; do
    sudo systemctl enable --now "$unit"
done

# --- Clean up services for channels/mountpoints no longer configured ------
step "Checking for stale services from a previous channel list"
for existing in /etc/systemd/system/stream-*.service; do
    [ -e "$existing" ] || continue
    unit_name="$(basename "$existing" .service)"
    keep=false
    for d in "${DESIRED_UNITS[@]}"; do [ "$d" = "$unit_name" ] && keep=true; done
    if [ "$keep" = false ]; then
        warn "removing stale service for a mountpoint no longer in channels.conf: $unit_name"
        sudo systemctl disable --now "$unit_name" 2>/dev/null || true
        sudo rm -f "/etc/systemd/system/${unit_name}.service"
        safe_stale="${unit_name#stream-}"
        sudo rm -f "$INSTALL_ROOT/streaming/${unit_name}.sh" "$INSTALL_ROOT/streaming/icecast-${safe_stale}.env"
    fi
done
sudo systemctl daemon-reload

step "Status"
sleep 3
for unit in "${DESIRED_UNITS[@]}"; do
    systemctl is-active --quiet "$unit" \
        && ok "$unit active" \
        || warn "$unit not active yet — check: sudo journalctl -u $unit -n 20"
done

echo
echo "=== Phase 6 complete ==="
echo "Verify with:"
echo "    sudo journalctl -u ${DESIRED_UNITS[0]} -f"
echo "Test automatic recovery (kills ffmpeg; systemd should relaunch within ~5s):"
echo "    sudo pkill -9 ffmpeg && sleep 6 && sudo systemctl status ${DESIRED_UNITS[0]} --no-pager"
