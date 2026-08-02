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
