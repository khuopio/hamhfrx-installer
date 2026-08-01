#!/bin/bash
# Phase 2 — dedicated service account and /opt directory layout. Idempotent.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
[ -f "$SCRIPT_DIR/hamhfrx.conf" ] || die "Run ./00-configure.sh first."
source "$SCRIPT_DIR/hamhfrx.conf"

[ "$EUID" -eq 0 ] && die "Run as your normal user (this script uses sudo internally where needed)."

step "Service account: $SERVICE_USER"
run_once "id $SERVICE_USER &>/dev/null" \
    sudo useradd --system --home-dir "$INSTALL_ROOT" --create-home \
        --shell /usr/sbin/nologin "$SERVICE_USER"

step "Directory layout under $INSTALL_ROOT"
sudo mkdir -p "$INSTALL_ROOT"/{bin,streaming,baresip-ch1,baresip-ch2,baresip-ch3}
sudo chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_ROOT"
ok "created bin/, streaming/, baresip-ch{1,2,3}/"

step "Group membership (USB + ALSA access — both required, see manual 6.4)"
run_once "id -nG $SERVICE_USER | grep -qw plugdev" sudo usermod -aG plugdev "$SERVICE_USER"
run_once "id -nG $SERVICE_USER | grep -qw audio"   sudo usermod -aG audio   "$SERVICE_USER"

step "Confirm"
id "$SERVICE_USER"

echo
echo "=== Phase 2 complete ==="
echo "Next: ./03-sdrplay-api.sh"
