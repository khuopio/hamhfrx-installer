#!/bin/bash
# Phase 4 — build SDRangel from source with the RSP2-capable sdrplayv3
# plugin. This is the long phase (45-90+ min on a Pi 4). The actual
# `make` runs fully detached (setsid + nohup) so it survives a dropped
# SSH/tunnel session — re-running this script later just checks on it
# and finishes the install once it's done. Idempotent throughout.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
[ -f "$SCRIPT_DIR/hamhfrx.conf" ] || die "Run ./00-configure.sh first."
source "$SCRIPT_DIR/hamhfrx.conf"

[ "$EUID" -eq 0 ] && die "Run as your normal user (this script uses sudo internally where needed)."

SDRANGEL_TAG="${SDRANGEL_TAG:-v7.22.7}"
BUILD_DIR="$SCRIPT_DIR/build/sdrangel"
BUILD_LOG="$SCRIPT_DIR/build/sdrangel-build.log"
BUILD_PID_FILE="$SCRIPT_DIR/build/sdrangel-build.pid"
mkdir -p "$SCRIPT_DIR/build"

# --- Already fully installed? -------------------------------------------
if [ -x "$SDRANGEL_PREFIX/bin/sdrangelsrv" ] && \
   find "$BUILD_DIR/build" -iname "*sdrplayv3*" 2>/dev/null | grep -q .; then
    skip "SDRangel already built and installed at $SDRANGEL_PREFIX with sdrplayv3 plugin"
    echo
    echo "=== Phase 4 already satisfied ==="
    echo "Next: ./05-sdrangel-config.sh"
    exit 0
fi

# --- A build already running in the background? --------------------------
if [ -f "$BUILD_PID_FILE" ] && kill -0 "$(cat "$BUILD_PID_FILE")" 2>/dev/null; then
    PID="$(cat "$BUILD_PID_FILE")"
    echo
    echo "   A build is already running in the background (PID $PID)."
    echo "   Watch progress with:"
    echo "       tail -f $BUILD_LOG"
    echo "   Re-run this script later — it will finish the install"
    echo "   automatically once the build completes."
    exit 0
fi

# --- A background build finished since the last run? ---------------------
# (PID file exists, but that process is no longer alive.) Check whether it
# succeeded and, if so, finish the install steps here.
if [ -f "$BUILD_PID_FILE" ]; then
    step "Previous background build has finished — checking result"
    if [ -x "$BUILD_DIR/build/sdrangelsrv" ] || \
       grep -q "^\[100%\] Built target sdrangelsrv" "$BUILD_LOG" 2>/dev/null; then
        ok "build completed successfully (per $BUILD_LOG)"

        step "Installing to $SDRANGEL_PREFIX"
        (cd "$BUILD_DIR/build" && sudo make install)
        sudo chown -R "$SERVICE_USER:$SERVICE_USER" "$SDRANGEL_PREFIX"
        ok "installed and owned by $SERVICE_USER"

        step "Verifying sdrplayv3 plugin was built"
        if find "$BUILD_DIR/build" -iname "*sdrplayv3*" 2>/dev/null | grep -q .; then
            ok "sdrplayv3 plugin present"
        else
            warn "sdrplayv3 plugin not found in build output — RSP2-specific features (antenna port, external ref clock) will not be available. Check $BUILD_LOG and $SCRIPT_DIR/build/cmake-configure.log"
        fi

        rm -f "$BUILD_PID_FILE"
        echo
        echo "=== Phase 4 complete ==="
        echo "Next: ./05-sdrangel-config.sh"
        exit 0
    else
        rm -f "$BUILD_PID_FILE"
        die "the background build exited without completing successfully. Check the tail of $BUILD_LOG for the actual compile error (often a missing -dev package — see manual §5.3), fix it, then re-run this script to start a fresh build."
    fi
fi

step "Prerequisite check: SDRplay API"
[ -f /usr/local/lib/libsdrplay_api.so ] || die "SDRplay API not found. Run ./03-sdrplay-api.sh first."

step "Build dependencies"
sudo apt-get update -qq
sudo apt-get -y -qq install \
  build-essential cmake git pkg-config \
  qtbase5-dev qtchooser qt5-qmake qtbase5-dev-tools \
  qtmultimedia5-dev libqt5multimedia5-plugins \
  qttools5-dev qttools5-dev-tools libqt5svg5-dev \
  qtdeclarative5-dev qtpositioning5-dev qtlocation5-dev \
  libqt5serialport5-dev libqt5websockets5-dev libqt5opengl5-dev \
  libfftw3-dev libusb-1.0-0-dev libasound2-dev zlib1g-dev libxml2-dev \
  libqt5charts5-dev libqt5texttospeech5-dev qtwebengine5-dev \
  libboost-all-dev libopus-dev tmux
ok "build dependencies installed"

step "Fetching source (tag $SDRANGEL_TAG)"
if [ -d "$BUILD_DIR/.git" ]; then
    (cd "$BUILD_DIR" && git fetch --tags -q && git checkout -q "$SDRANGEL_TAG")
    ok "source updated to $SDRANGEL_TAG"
else
    git clone -q https://github.com/f4exb/sdrangel.git "$BUILD_DIR"
    (cd "$BUILD_DIR" && git checkout -q "$SDRANGEL_TAG")
    ok "source cloned at $SDRANGEL_TAG"
fi

step "Configuring build (scoped to SDRplay-only, server binary only)"
mkdir -p "$BUILD_DIR/build"
(
  cd "$BUILD_DIR/build"
  export CXXFLAGS='-O3 -mtune=cortex-a72'
  export CFLAGS='-O3 -mtune=cortex-a72'
  cmake -Wno-dev -DCMAKE_BUILD_TYPE=Release -DBUILD_GUI=OFF -DBUILD_SERVER=ON \
    -DCMAKE_INSTALL_PREFIX="$SDRANGEL_PREFIX" .. 2>&1 | tee "$SCRIPT_DIR/build/cmake-configure.log"
)

if ! grep -q "Found SDRPLAY" "$SCRIPT_DIR/build/cmake-configure.log"; then
    die "cmake did not report 'Found SDRPLAY' — the sdrplayv3 plugin will not be built. Check $SCRIPT_DIR/build/cmake-configure.log and confirm phase 3 completed correctly."
fi
if grep -q "^CMake Error" "$SCRIPT_DIR/build/cmake-configure.log"; then
    die "cmake reported a fatal error — see $SCRIPT_DIR/build/cmake-configure.log. A missing optional hardware plugin dependency is fine; a hard CMake Error is not."
fi
ok "configure clean, SDRplay API found"

step "Launching build in the background"
echo "   Log: $BUILD_LOG"
echo "   This takes 45-90+ minutes on a Pi 4. It is fully detached — you"
echo "   can close this SSH session, the tunnel can drop, and the build"
echo "   keeps going regardless. Watch it with:"
echo "       tail -f $BUILD_LOG"
echo "   Re-run this script at any point; it will detect whether the"
echo "   build is still running, and finish the install once it's done."
echo

cd "$BUILD_DIR/build"
setsid nohup make -j"$(nproc)" > "$BUILD_LOG" 2>&1 < /dev/null &
BUILD_PID=$!
disown
echo "$BUILD_PID" > "$BUILD_PID_FILE"
ok "build started, PID $BUILD_PID"

echo
echo "=== Phase 4 started, not yet complete ==="
echo "Re-run ./04-sdrangel-build.sh later to check on it and finish install."
