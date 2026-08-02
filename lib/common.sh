#!/bin/bash
# Shared helpers for all hamhfrx-installer phase scripts.
# Sourced, not executed directly.

INSTALLER_LOG="${INSTALLER_LOG:-/var/log/hamhfrx-installer.log}"
sudo touch "$INSTALLER_LOG" 2>/dev/null || true
sudo chmod 644 "$INSTALLER_LOG" 2>/dev/null || true

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | sudo tee -a "$INSTALLER_LOG" >/dev/null; }
step() { echo; echo "== $* =="; log "STEP: $*"; }
ok()   { echo "   ok: $*"; log "OK: $*"; }
skip() { echo "   skip (already done): $*"; log "SKIP: $*"; }
warn() { echo "   WARNING: $*"; log "WARN: $*"; }
die()  { echo "   FATAL: $*" >&2; log "FATAL: $*"; exit 1; }

# Idempotency helper: run $2.. only if $1 (a shell test expression, already
# evaluated as a command) is false. Example:
#   run_once "id hamsvc &>/dev/null" "sudo useradd ..."
run_once() {
    local check="$1"; shift
    if eval "$check" &>/dev/null; then
        skip "$*"
    else
        "$@"
        ok "$*"
    fi
}

require_var() {
    local name="$1"
    if [ -z "${!name}" ]; then
        die "Required variable $name is not set. Check hamhfrx.conf."
    fi
}

confirm() {
    local prompt="$1"
    read -r -p "$prompt [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

# --- Optional recording ring buffer (RAM-backed, tmpfs) --------------------
# Only relevant if at least one channel is listed in recordings.conf.
# Hard-capped size — this is real RAM, not disk. A misconfiguration here
# should fail loudly (writes stop, ENOSPC) rather than threaten system
# stability the way an unbounded buffer could.
BUFFER_DIR="${INSTALL_ROOT:-/opt/hamhfrx1}/recording/buffer"
BUFFER_SIZE_MB="${BUFFER_SIZE_MB:-256}"
BUFFER_RETENTION_MIN="${BUFFER_RETENTION_MIN:-60}"
BUFFER_SEGMENT_SEC="${BUFFER_SEGMENT_SEC:-300}"

ensure_recording_buffer() {
    sudo mkdir -p "$BUFFER_DIR"
    if ! grep -q "$BUFFER_DIR" /etc/fstab 2>/dev/null; then
        echo "tmpfs $BUFFER_DIR tmpfs rw,nosuid,nodev,noexec,size=${BUFFER_SIZE_MB}m,mode=0750 0 0" | sudo tee -a /etc/fstab >/dev/null
        ok "added recording ring buffer to /etc/fstab (tmpfs, ${BUFFER_SIZE_MB}MB hard cap)"
    fi
    if ! mountpoint -q "$BUFFER_DIR"; then
        sudo mount "$BUFFER_DIR"
        ok "recording ring buffer mounted (RAM-backed — never touches the SD card)"
    else
        skip "recording ring buffer already mounted"
    fi
    sudo chown "$SERVICE_USER:$SERVICE_USER" "$BUFFER_DIR"
}
