#!/bin/bash
# Phase 5 — ALSA loopback devices (one pair per channel, count driven by
# channels.conf), SDRangel systemd units, and REST-API provisioning of
# the device set + N demod channels (SSB LSB/USB or AM, per channel).
#
# Re-run this any time after editing channels.conf to apply changes —
# it always restarts sdrangelsrv and reprovisions from a clean slate,
# since SDRangel's REST API isn't designed to diff/patch an existing
# device set against a changed channel count. A brief interruption of
# any active streams during reconfiguration is expected; re-run
# ./06-streaming.sh afterward to bring them back up matching the new
# channel list.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/channels.sh"
[ -f "$SCRIPT_DIR/hamhfrx.conf" ] || die "Run ./00-configure.sh first."
source "$SCRIPT_DIR/hamhfrx.conf"

[ "$EUID" -eq 0 ] && die "Run as your normal user (this script uses sudo internally where needed)."
[ -x "$SDRANGEL_PREFIX/bin/sdrangelsrv" ] || die "SDRangel not built yet. Run ./04-sdrangel-build.sh first."

load_channels "$CHANNELS_FILE"
N="${#CHAN_FREQ_KHZ[@]}"
step "Loaded $N channel(s) from $CHANNELS_FILE"
for i in "${!CHAN_FREQ_KHZ[@]}"; do
    echo "   ch$((i+1)): ${CHAN_FREQ_KHZ[$i]} kHz  ${CHAN_MODE[$i]}  -> ${CHAN_MOUNT[$i]}"
done

CENTER_FREQ_HZ=$(compute_center_freq_hz)
check_span_fits "$SAMPLE_RATE_HZ"
ok "center frequency: $CENTER_FREQ_HZ Hz"

case "${ANTENNA_PORT^^}" in
    A)   ANTENNA_NUM=0 ;;
    B)   ANTENNA_NUM=1 ;;
    HIZ) ANTENNA_NUM=2 ;;
    *)   warn "unrecognized ANTENNA_PORT '$ANTENNA_PORT', defaulting to Antenna A"; ANTENNA_NUM=0 ;;
esac
BANDWIDTH_INDEX=7   # widest analog IF filter — safe default at multi-MHz sample rates

# --- Stop consumers before touching the loopback module count ------------
step "Stopping any active services that hold the loopback devices open"
sudo systemctl stop sdrangelsrv 2>/dev/null || true
RUNNING_STREAMS="$(systemctl list-units --type=service --state=running 'stream-*' --no-legend 2>/dev/null | awk '{print $1}')"
if [ -n "$RUNNING_STREAMS" ]; then
    sudo systemctl stop $RUNNING_STREAMS
    warn "stopped running stream service(s): $RUNNING_STREAMS — re-run ./06-streaming.sh after this phase finishes"
fi

# --- ALSA loopback devices, sized to N channels ---------------------------
step "ALSA loopback devices ($N card pair(s))"
ENABLE_LIST="$(printf '1,%.0s' $(seq 1 "$N") | sed 's/,$//')"
INDEX_LIST="$(seq -s, 10 $((10 + N - 1)))"
sudo bash -c "echo 'options snd-aloop enable=$ENABLE_LIST index=$INDEX_LIST' > /etc/modprobe.d/snd-aloop.conf"
run_once "grep -qx snd-aloop /etc/modules" sudo bash -c "echo snd-aloop >> /etc/modules"
sudo rmmod snd_aloop 2>/dev/null || true
sudo modprobe snd-aloop enable=$ENABLE_LIST index=$INDEX_LIST
aplay -l | grep -qi loopback && ok "loopback cards present (enable=$ENABLE_LIST index=$INDEX_LIST)" || die "loopback cards did not appear — check dmesg"

# --- sdrangelsrv systemd unit ----------------------------------------------
step "sdrangelsrv systemd unit"
sudo tee /etc/systemd/system/sdrangelsrv.service >/dev/null <<EOF
[Unit]
Description=SDRangel headless server
After=network.target sdrplay.service
Wants=sdrplay.service

[Service]
Type=simple
User=$SERVICE_USER
ExecStart=$SDRANGEL_PREFIX/bin/sdrangelsrv
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo mkdir -p /etc/systemd/system/sdrangelsrv.service.d
sudo tee /etc/systemd/system/sdrangelsrv.service.d/override.conf >/dev/null <<'EOF'
[Unit]
After=network.target sdrplay.service systemd-modules-load.service
Wants=sdrplay.service
Requires=systemd-modules-load.service

[Service]
# Required — without real-time scheduling the audio output threads are
# not scheduled promptly enough and every channel's audio FIFO overflows
# continuously, even though CPU headroom looks fine in `top`.
CPUSchedulingPolicy=rr
CPUSchedulingPriority=50
EOF
ok "unit + override written (RT scheduling, module-load ordering)"

sudo systemctl daemon-reload
sudo systemctl enable --now sdrangelsrv
ok "sdrangelsrv (re)started"

step "Waiting for the REST API to come up"
API="http://127.0.0.1:8091/sdrangel"
if ! timeout 60 bash -c "until curl -s -o /dev/null '$API/presets'; do sleep 1; done"; then
    die "sdrangelsrv REST API did not come up within 60s. Check: sudo journalctl -u sdrangelsrv -n 50"
fi
ok "REST API responding"

# --- Build the provisioning script, one block per channel -----------------
step "Writing provisioning script for $N channel(s)"
PROV="$INSTALL_ROOT/bin/provision-sdrangel.sh"
TMP_PROV="$(mktemp)"

cat > "$TMP_PROV" <<HEADEOF
#!/bin/bash
set -e
API="http://127.0.0.1:8091/sdrangel"

timeout 60 bash -c "until curl -s -o /dev/null '\$API/presets'; do echo 'Waiting for sdrangelsrv API...'; sleep 1; done"

curl -s -X POST "\$API/deviceset" > /dev/null
curl -s -X PUT "\$API/deviceset/0/device" -H "Content-Type: application/json" \\
  -d '{"hwType": "SDRplayV3", "sequence": 0}' > /dev/null
curl -s -X PATCH "\$API/deviceset/0/device/settings" -H "Content-Type: application/json" \\
  -d '{"deviceHwType": "SDRplayV3", "sdrPlayV3Settings": {"centerFrequency": $CENTER_FREQ_HZ, "devSampleRate": $SAMPLE_RATE_HZ, "bandwidthIndex": $BANDWIDTH_INDEX, "log2Decim": 0, "antenna": $ANTENNA_NUM, "extRef": 0}}' > /dev/null
curl -s -X POST "\$API/deviceset/0/device/run" > /dev/null

sleep 20   # RSP2 Pro firmware upload + RF settle — happens on every session open

HEADEOF

for i in "${!CHAN_FREQ_KHZ[@]}"; do
    idx=$i   # 0-based channel index within the device set
    pos=$((i + 1))
    freq_khz="${CHAN_FREQ_KHZ[$i]}"
    mode="${CHAN_MODE[$i]}"
    title="${freq_khz} kHz ${mode}"
    offset_hz=$(( freq_khz * 1000 - CENTER_FREQ_HZ ))
    card="$(loopback_card_name "$pos")"
    audio_device="hw:CARD=${card},DEV=0"

    if [ "$mode" = "AM" ]; then
        channel_type="AMDemod"
        # NOTE: AM has no sideband — a single symmetric bandwidth setting,
        # not the signed rfBandwidth/lowCutoff pair SSB uses. Field names
        # below match SDRangel v7.22.7's AMDemodSettings; if you're on a
        # different version, verify with:
        #   curl -s http://127.0.0.1:8091/sdrangel/deviceset/0/channel/<n>/settings
        # after this script creates the channel, the same way every other
        # value in this build was verified against the live system rather
        # than assumed from documentation.
        settings_json="{\"channelType\": \"AMDemod\", \"AMDemodSettings\": {\"inputFrequencyOffset\": $offset_hz, \"rfBandwidth\": 6000, \"audioDeviceName\": \"$audio_device\", \"audioMute\": 0, \"title\": \"$title\"}}"
    else
        channel_type="SSBDemod"
        if [ "$mode" = "LSB" ]; then bw=-3000; lc=-300; else bw=3000; lc=300; fi
        settings_json="{\"channelType\": \"SSBDemod\", \"SSBDemodSettings\": {\"inputFrequencyOffset\": $offset_hz, \"rfBandwidth\": $bw, \"lowCutoff\": $lc, \"audioDeviceName\": \"$audio_device\", \"audioMute\": 0, \"title\": \"$title\"}}"
    fi

    cat >> "$TMP_PROV" <<CHANEOF
curl -s -X POST "\$API/deviceset/0/channel" -H "Content-Type: application/json" \\
  -d '{"channelType": "$channel_type", "direction": 0}' > /dev/null
curl -s -X PATCH "\$API/deviceset/0/channel/$idx/settings" -H "Content-Type: application/json" \\
  -d '$settings_json' > /dev/null

CHANEOF
done

echo 'echo "Provisioning complete: '"$N"' channel(s)."' >> "$TMP_PROV"

# NOTE (fixed in v2.1): mktemp creates $TMP_PROV owned by the invoking
# user (mode 600) — hamsvc cannot read it directly, so "sudo -u hamsvc
# cp" fails with Permission denied. Copy as root, then hand ownership to
# hamsvc afterward.
sudo cp "$TMP_PROV" "$PROV"
sudo chown "$SERVICE_USER:$SERVICE_USER" "$PROV"
rm -f "$TMP_PROV"
sudo chmod +x "$PROV"
ok "provisioning script written: $N channel(s), center $CENTER_FREQ_HZ Hz, antenna $ANTENNA_PORT"

step "Provisioning systemd unit"
sudo tee /etc/systemd/system/sdrangel-provision.service >/dev/null <<EOF
[Unit]
Description=Provision SDRangel device set and channels
After=sdrangelsrv.service
Requires=sdrangelsrv.service

[Service]
Type=oneshot
User=$SERVICE_USER
ExecStart=$PROV

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable sdrangel-provision >/dev/null 2>&1

step "Running provisioning now (takes ~2-3 minutes — RSP2 firmware upload)"
sudo systemctl restart sdrangel-provision
sudo systemctl status sdrangel-provision --no-pager | grep -q "code=exited, status=0/SUCCESS" \
    && ok "provisioning completed successfully" \
    || die "provisioning did not complete cleanly — check: sudo journalctl -u sdrangel-provision -n 40"

step "Verifying reception on all $N channel(s)"
for i in "${!CHAN_FREQ_KHZ[@]}"; do
    echo "-- ${CHAN_FREQ_KHZ[$i]} kHz ${CHAN_MODE[$i]} --"
    curl -s "http://127.0.0.1:8091/sdrangel/deviceset/0/channel/$i/report" | python3 -m json.tool || true
done

echo
echo "=== Phase 5 complete ==="
if [ -n "$RUNNING_STREAMS" ]; then
    echo "Streaming services were stopped to safely reconfigure the loopback"
    echo "devices — re-run ./06-streaming.sh now to bring them back up."
else
    echo "Next: ./06-streaming.sh"
fi
