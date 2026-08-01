#!/bin/bash
# Phase 3 — SDRplay API. Idempotent, but the download step is manual by
# necessity: it's a proprietary installer with a license-acceptance
# prompt and no stable long-term URL to fetch programmatically.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
[ -f "$SCRIPT_DIR/hamhfrx.conf" ] || die "Run ./00-configure.sh first."
source "$SCRIPT_DIR/hamhfrx.conf"

[ "$EUID" -eq 0 ] && die "Run as your normal user (this script uses sudo internally where needed)."

DOWNLOAD_DIR="$SCRIPT_DIR/downloads"
mkdir -p "$DOWNLOAD_DIR"

step "Checking whether the SDRplay API is already installed"
if [ -f /usr/local/lib/libsdrplay_api.so ] && systemctl is-active --quiet sdrplay 2>/dev/null; then
    skip "SDRplay API already installed and service running"
    lsusb | grep -i sdrplay && ok "RSP2 Pro visible on USB" || warn "API installed but no RSP2 Pro currently detected on USB — check the cable/connection"
    echo
    echo "=== Phase 3 already satisfied ==="
    echo "Next: ./04-sdrangel-build.sh"
    exit 0
fi

step "Looking for a downloaded installer in $DOWNLOAD_DIR"
INSTALLER="$(find "$DOWNLOAD_DIR" -maxdepth 1 -iname 'SDRplay_RSP_API-Linux-*.run' 2>/dev/null | sort -V | tail -1)"

if [ -z "$INSTALLER" ]; then
    cat <<EOF

   No SDRplay API installer found in:
       $DOWNLOAD_DIR

   This has to be fetched by hand — SDRplay's download page requires
   accepting a license and the exact filename/version changes over time,
   so it can't be hardcoded into this script.

   1. On this machine (or download elsewhere and scp it over), open:
          https://www.sdrplay.com/downloads/
   2. Get the current ARM64 / aarch64 Linux API installer
      (SDRplay_RSP_API-Linux-<version>.run)
   3. Save it into:
          $DOWNLOAD_DIR
   4. Re-run this script:
          ./03-sdrplay-api.sh

EOF
    exit 1
fi

step "Found installer: $(basename "$INSTALLER")"
chmod +x "$INSTALLER"

echo
echo "   The installer will now run. It includes an interactive license"
echo "   acceptance prompt — this cannot be skipped or scripted around."
echo
sudo "$INSTALLER"

step "Verifying install"
[ -f /usr/local/lib/libsdrplay_api.so ] || die "libsdrplay_api.so not found after install — installer may have failed."
ok "libsdrplay_api.so present"

sudo systemctl enable sdrplay >/dev/null 2>&1 || true
sudo systemctl restart sdrplay
sleep 2
systemctl is-active --quiet sdrplay && ok "sdrplay.service running" || die "sdrplay.service failed to start — check: sudo journalctl -u sdrplay"

step "USB device check"
if lsusb | grep -qi sdrplay; then
    ok "RSP2 Pro visible on USB"
else
    warn "API installed correctly but no RSP2 Pro currently detected on USB. Connect it now and check with: lsusb | grep -i sdrplay"
fi

echo
echo "=== Phase 3 complete ==="
echo "Next: ./04-sdrangel-build.sh   (this one takes 45-90+ minutes)"
