#!/bin/bash
# Shared recording-schedule parsing. Sourced, not executed directly.
#
# recordings.conf format — one scheduled recording per line:
#     mountpoint | OnCalendar_expr | duration_min | ssh_target | remote_path
#
# - mountpoint must match an entry already in channels.conf.
# - OnCalendar_expr is systemd calendar syntax, e.g. "*-*-* 14:00:00"
#   for daily at 14:00, or "Mon *-*-* 08:00:00" for weekly.
# - ssh_target is user@host for the destination system.
# - remote_path is the destination directory on that system.
#
# This file is NOT committed to git — it names a real remote host and
# path, same treatment as hamhfrx.conf/channels.conf. See .gitignore.

load_recordings() {
    local file="$1"
    REC_MOUNT=(); REC_SCHEDULE=(); REC_DURATION_MIN=(); REC_SSH_TARGET=(); REC_REMOTE_PATH=()
    [ -f "$file" ] || die "Recordings file not found: $file (create it by hand — see README)"

    while IFS= read -r rawline || [ -n "$rawline" ]; do
        # Same comment handling as lib/channels.sh: strip from the first
        # '#' to end of line before splitting, so whole-line AND trailing
        # comments both work safely.
        line="${rawline%%#*}"
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue

        IFS='|' read -r mount schedule duration target path <<< "$line"
        mount="$(echo "$mount" | xargs)"
        [ -z "$mount" ] && die "Malformed line in $file (no mountpoint): $rawline"
        schedule="$(echo "$schedule" | xargs)"
        duration="$(echo "$duration" | xargs)"
        target="$(echo "$target" | xargs)"
        path="$(echo "$path" | xargs)"

        [ -z "$schedule" ] && die "Recording for '$mount' in $file has no schedule (OnCalendar expression)"
        [[ "$duration" =~ ^[0-9]+$ ]] || die "Recording for '$mount' in $file has an invalid duration_min: '$duration'"
        [[ "$target" == *@* ]] || die "Recording for '$mount' in $file has an invalid ssh_target (expected user@host): '$target'"
        [ -z "$path" ] && die "Recording for '$mount' in $file has no remote_path"

        REC_MOUNT+=("$mount")
        REC_SCHEDULE+=("$schedule")
        REC_DURATION_MIN+=("$duration")
        REC_SSH_TARGET+=("$target")
        REC_REMOTE_PATH+=("$path")
    done < "$file"

    [ "${#REC_MOUNT[@]}" -ge 1 ] || die "No recordings defined in $file"
}

# Cross-validate every recording's mountpoint actually exists among the
# currently-configured receiver channels — catches a typo or a channel
# that was since removed from channels.conf, before any systemd unit
# gets built around a mountpoint that doesn't exist.
validate_recordings_against_channels() {
    local mount found
    for mount in "${REC_MOUNT[@]}"; do
        found=false
        for c in "${CHAN_MOUNT[@]}"; do
            [ "$c" = "$mount" ] && found=true
        done
        [ "$found" = true ] || die "recordings.conf references mountpoint '$mount', which is not in channels.conf"
    done
}

# Sanitize a mountpoint the same way 06-streaming.sh does, so recording
# systemd units and streaming systemd units use a consistent naming
# scheme for the same channel.
sanitize_name() { printf '%s' "$1" | tr -c 'A-Za-z0-9_' '-'; }
