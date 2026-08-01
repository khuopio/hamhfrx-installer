#!/bin/bash
# Shared channel-list parsing. Sourced, not executed directly.
#
# channels.conf format — one channel per line, pipe-delimited:
#     freq_khz|MODE|mountpoint|gain_db
# MODE is one of LSB, USB, AM (case-insensitive).
# gain_db is optional, defaults to 0. Blank lines and lines starting
# with # are ignored. This file is meant to be hand-edited: add,
# remove, or change channels, then re-run 05-sdrangel-config.sh and
# 06-streaming.sh to apply.
#
# Example:
#   # freq_khz | mode | mountpoint | gain_db
#   3600 | LSB | ch1 | 10
#   7100 | LSB | ch2 |
#   4700 | USB | ch3 |
#   6000 | AM  | ch4 |

load_channels() {
    local file="$1"
    CHAN_FREQ_KHZ=(); CHAN_MODE=(); CHAN_MOUNT=(); CHAN_GAIN_DB=()
    [ -f "$file" ] || die "Channels file not found: $file (run ./00-configure.sh, or create it by hand)"

    while IFS= read -r rawline || [ -n "$rawline" ]; do
        # Strip everything from the first '#' to end of line — this
        # handles a whole-line comment AND a trailing comment after real
        # data on the same line, uniformly, before any field splitting
        # happens. A line that's blank after stripping (whitespace-only,
        # or fully commented) is skipped entirely.
        line="${rawline%%#*}"
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue

        IFS='|' read -r freq mode mount gain <<< "$line"
        freq="$(echo "$freq" | xargs)"
        [ -z "$freq" ] && die "Malformed line in $file (no frequency): $rawline"
        mode="$(echo "$mode" | xargs | tr '[:lower:]' '[:upper:]')"
        mount="$(echo "$mount" | xargs)"
        gain="$(echo "$gain" | xargs)"
        [ -z "$gain" ] && gain=0

        case "$mode" in
            LSB|USB|AM) ;;
            *) die "Unrecognized mode '$mode' for channel at $freq kHz in $file (must be LSB, USB, or AM)" ;;
        esac
        [ -z "$mount" ] && die "Channel at $freq kHz in $file has no mountpoint name"

        CHAN_FREQ_KHZ+=("$freq")
        CHAN_MODE+=("$mode")
        CHAN_MOUNT+=("$mount")
        CHAN_GAIN_DB+=("$gain")
    done < "$file"

    [ "${#CHAN_FREQ_KHZ[@]}" -ge 1 ] || die "No channels defined in $file"

    # Each mountpoint becomes both an Icecast mount and a systemd service
    # name (stream-<mountpoint>) — a duplicate would make one channel
    # silently overwrite the other's stream/service with no error.
    local -A seen_mounts
    for mount in "${CHAN_MOUNT[@]}"; do
        if [ -n "${seen_mounts[$mount]:-}" ]; then
            die "Duplicate mountpoint '$mount' in $file — each channel needs a unique mountpoint."
        fi
        seen_mounts[$mount]=1
    done
}

# ALSA loopback card naming as SDRangel/ALSA itself reports it: the first
# card is plain "Loopback", every subsequent one is "Loopback_<n>" where n
# is its 0-based position among the *extra* cards. 1-indexed input.
loopback_card_name() {
    local i="$1"
    if [ "$i" -eq 1 ]; then echo "Loopback"; else echo "Loopback_$((i - 1))"; fi
}

# Center frequency: midpoint between the lowest and highest configured
# channel, which maximizes margin on both edges of the captured span.
compute_center_freq_hz() {
    local min=999999999 max=0
    for f in "${CHAN_FREQ_KHZ[@]}"; do
        local hz=$((f * 1000))
        [ "$hz" -lt "$min" ] && min=$hz
        [ "$hz" -gt "$max" ] && max=$hz
    done
    echo $(( (min + max) / 2 ))
}

# Warn (does not block) if the channel spread is tight relative to the
# configured sample rate. ~80% of sample rate is a reasonable rule of
# thumb for clean usable bandwidth before edge filter roll-off.
check_span_fits() {
    local sample_rate_hz="$1"
    local min=999999999 max=0
    for f in "${CHAN_FREQ_KHZ[@]}"; do
        local hz=$((f * 1000))
        [ "$hz" -lt "$min" ] && min=$hz
        [ "$hz" -gt "$max" ] && max=$hz
    done
    local span=$((max - min))
    local usable=$((sample_rate_hz * 80 / 100))
    if [ "$span" -gt "$usable" ]; then
        warn "channel spread is ${span} Hz, but only ~${usable} Hz is comfortably usable at a ${sample_rate_hz} Hz sample rate."
        warn "Either raise the sample rate in hamhfrx.conf, narrow the channel selection, or accept reduced margin at the outer channels."
    fi
}
