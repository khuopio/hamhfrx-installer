#!/bin/bash
# Phase 0 — collect configuration once, write to hamhfrx.conf and
# channels.conf. Every later phase reads these instead of prompting
# again. channels.conf is deliberately a separate, plain, hand-editable
# file (no secrets in it) — add, remove, or change channels later just
# by editing it directly and re-running 05 and 06.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/channels.sh"

CONF_FILE="$SCRIPT_DIR/hamhfrx.conf"
CHANNELS_FILE="$SCRIPT_DIR/channels.conf"

if [ -f "$CONF_FILE" ]; then
    echo "Existing config found at $CONF_FILE."
    if ! confirm "Overwrite it and reconfigure from scratch?"; then
        echo "Keeping existing config. To change just the channel list,"
        echo "edit $CHANNELS_FILE directly instead — no need to re-run this."
        exit 0
    fi
fi

echo "=== hamhfrx-installer: initial configuration ==="
echo

read -r -p "Hostname for this station [sdr-station-1]: " HOSTNAME
HOSTNAME="${HOSTNAME:-sdr-station-1}"

read -r -p "Admin username to keep (existing login user, not the service account): " ADMIN_USER
[ -z "$ADMIN_USER" ] && die "Admin username is required."

read -r -p "Path to SSH public key to authorize for $ADMIN_USER [blank to add manually later]: " SSH_PUBKEY_PATH

read -r -p "Timezone (e.g. UTC, America/New_York): " TIMEZONE
[ -z "$TIMEZONE" ] && die "Timezone is required (see /usr/share/zoneinfo for valid names)."

read -r -p "SDRplay antenna port (A/B/HIZ) [A]: " ANTENNA_PORT
ANTENNA_PORT="${ANTENNA_PORT:-A}"

read -r -p "Device sample rate in Hz [6000000]: " SAMPLE_RATE_HZ
SAMPLE_RATE_HZ="${SAMPLE_RATE_HZ:-6000000}"

echo
echo "-- Receiver channels --"
echo "Add as many as you like. Each needs a frequency, a modulation"
echo "(LSB / USB / AM), and an Icecast mountpoint name."
echo

CHAN_FREQ_KHZ=(); CHAN_MODE=(); CHAN_MOUNT=(); CHAN_GAIN_DB=()
n=0
while true; do
    n=$((n + 1))
    echo "Channel $n:"
    read -r -p "  frequency in kHz (blank to stop adding channels): " freq
    [ -z "$freq" ] && { n=$((n - 1)); break; }

    mode=""
    while [[ ! "$mode" =~ ^(LSB|USB|AM)$ ]]; do
        read -r -p "  mode (LSB/USB/AM): " mode
        mode="$(echo "$mode" | tr '[:lower:]' '[:upper:]')"
    done

    read -r -p "  Icecast mountpoint [ch${n}]: " mount
    mount="${mount:-ch${n}}"

    read -r -p "  gain adjustment in dB, if this channel needs a boost [0]: " gain
    gain="${gain:-0}"

    CHAN_FREQ_KHZ+=("$freq"); CHAN_MODE+=("$mode"); CHAN_MOUNT+=("$mount"); CHAN_GAIN_DB+=("$gain")
done
[ "$n" -ge 1 ] || die "At least one channel is required."

echo
echo "-- Icecast server (shared by all channels; each gets its own mountpoint above) --"
read -r -p "Icecast host [blank to configure later]: " ICECAST_HOST
read -r -p "Icecast port [8000]: " ICECAST_PORT
ICECAST_PORT="${ICECAST_PORT:-8000}"
read -r -s -p "Icecast source password (input hidden, blank to configure later): " ICECAST_PASSWORD
echo

echo
echo "-- Cloudflare Tunnel (requires an interactive browser login later; leave blank to skip) --"
read -r -p "Set up Cloudflare Tunnel now? (y/N): " SETUP_TUNNEL_ANS
[[ "$SETUP_TUNNEL_ANS" =~ ^[Yy]$ ]] && SETUP_TUNNEL=yes || SETUP_TUNNEL=no
read -r -p "Tunnel admin hostname (e.g. sdr-station-1-ssh.example.com), blank if skipping: " TUNNEL_HOSTNAME

# --- Write channels.conf ---------------------------------------------------
{
    echo "# freq_khz | mode | mountpoint | gain_db"
    echo "# Hand-edit this file to add/remove/change channels, then re-run"
    echo "# ./05-sdrangel-config.sh and ./06-streaming.sh to apply."
    for i in "${!CHAN_FREQ_KHZ[@]}"; do
        printf '%s | %s | %s | %s\n' "${CHAN_FREQ_KHZ[$i]}" "${CHAN_MODE[$i]}" "${CHAN_MOUNT[$i]}" "${CHAN_GAIN_DB[$i]}"
    done
} > "$CHANNELS_FILE"
chmod 644 "$CHANNELS_FILE"

# --- Preview center frequency / span, using the same logic 05 will use ----
CENTER_PREVIEW=$(compute_center_freq_hz)
echo
echo "Preview: center frequency would be ${CENTER_PREVIEW} Hz at ${SAMPLE_RATE_HZ} Hz sample rate."
check_span_fits "$SAMPLE_RATE_HZ"

# --- Write hamhfrx.conf (secrets — chmod 600) ------------------------------
cat > "$CONF_FILE" <<EOF
# hamhfrx-installer configuration — generated $(date '+%Y-%m-%d %H:%M:%S')
# Channel list lives separately in channels.conf (no secrets, hand-editable).

HOSTNAME="$HOSTNAME"
ADMIN_USER="$ADMIN_USER"
SSH_PUBKEY_PATH="$SSH_PUBKEY_PATH"
TIMEZONE="$TIMEZONE"

ANTENNA_PORT="$ANTENNA_PORT"
SAMPLE_RATE_HZ="$SAMPLE_RATE_HZ"

ICECAST_HOST="$ICECAST_HOST"
ICECAST_PORT="$ICECAST_PORT"
ICECAST_PASSWORD="$ICECAST_PASSWORD"

SETUP_TUNNEL="$SETUP_TUNNEL"
TUNNEL_HOSTNAME="$TUNNEL_HOSTNAME"

SERVICE_USER="hamsvc"
INSTALL_ROOT="/opt/hamhfrx1"
SDRANGEL_PREFIX="/opt/install/sdrangel"
CHANNELS_FILE="$CHANNELS_FILE"
EOF
chmod 600 "$CONF_FILE"

echo
echo "Saved:"
echo "  $CONF_FILE   (permissions restricted — holds the Icecast password)"
echo "  $CHANNELS_FILE   ($n channel(s), freely editable, no secrets)"
echo "Next: ./01-hardening.sh"
