#!/bin/bash
#
# bt-audio-release.sh
# Disconnects Bluetooth audio devices from this Mac when audio is idle,
# so other devices (phone, iPad, etc.) can use them.
# Auto-reconnects when audio starts playing again.
#
# Conditions to disconnect:
#   1. Lid is closed (clamshell mode)
#   2. No audio has been playing for IDLE_TIMEOUT seconds
#
# Dependencies: blueutil, nowplaying-cli, SwitchAudioSource (all via Homebrew)

IDLE_TIMEOUT=120       # seconds of silence before disconnecting
POLL_INTERVAL=15       # seconds between checks
STATE_FILE="/tmp/bt-audio-release-last-playing"
DISCONNECTED_FILE="/tmp/bt-audio-release-disconnected"
LOG_FILE="$HOME/.local/bt-audio-release.log"

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
    # NOTE: Keep log file from growing unbounded
    tail -500 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
}

is_audio_device() {
    local name="$1"
    local cleaned
    cleaned=$(echo "$name" | sed 's/[^a-zA-Z0-9 ]//g')
    echo "$AUDIO_OUTPUTS" | grep -qi "$cleaned"
}

get_connected_audio_devices() {
    # Returns "addr|name" lines for connected BT audio devices
    blueutil --paired --format json 2>/dev/null | python3 -c "
import json, sys
devices = json.load(sys.stdin)
for d in devices:
    if d.get('connected', False):
        print(d['address'] + '|' + d['name'])
" 2>/dev/null | while IFS='|' read -r addr name; do
        [ -z "$addr" ] && continue
        if is_audio_device "$name"; then
            echo "$addr|$name"
        fi
    done
}

# PATH setup for Homebrew binaries (LaunchAgents don't inherit shell PATH)
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# Verify dependencies
for cmd in blueutil nowplaying-cli SwitchAudioSource; do
    if ! command -v "$cmd" &>/dev/null; then
        log "ERROR: $cmd not found. Install via: brew install $cmd"
        exit 1
    fi
done

# Initialize state
date +%s > "$STATE_FILE"
# NOTE: Clear stale disconnected-device file on startup so we don't
# auto-reconnect something the user manually disconnected before reboot
rm -f "$DISCONNECTED_FILE"
PREV_LID_CLOSED=0
log "Started bt-audio-release daemon (idle_timeout=${IDLE_TIMEOUT}s, poll=${POLL_INTERVAL}s)"

while true; do
    sleep "$POLL_INTERVAL"

    # --- Check lid state ---
    LID_CLOSED=0
    if ioreg -r -k AppleClamshellState -d 4 2>/dev/null | grep -q '"AppleClamshellState" = Yes'; then
        LID_CLOSED=1
    fi

    # --- Check if audio is playing ---
    # nowplaying-cli returns "1" for playing, "0" for paused, "null"/empty for nothing
    PLAYBACK_RATE=$(nowplaying-cli get playbackRate 2>/dev/null)
    AUDIO_PLAYING=0
    if [ "$PLAYBACK_RATE" = "1" ]; then
        AUDIO_PLAYING=1
        date +%s > "$STATE_FILE"
    fi

    # Also check pmset for active audio OUTPUT assertions (catches Zoom, Meet, etc.
    # that don't report to Now Playing). Look for "output" streams specifically.
    if pmset -g assertions 2>/dev/null | grep -q "com.apple.audio.*:output"; then
        AUDIO_PLAYING=1
        date +%s > "$STATE_FILE"
    fi

    LAST_PLAYING=$(cat "$STATE_FILE" 2>/dev/null || date +%s)
    NOW=$(date +%s)
    IDLE_SECS=$((NOW - LAST_PLAYING))

    # --- Get list of audio output device names (used by is_audio_device) ---
    AUDIO_OUTPUTS=$(SwitchAudioSource -a -t output 2>/dev/null)

    # --- Detect lid just opened ---
    LID_JUST_OPENED=0
    if [ "$PREV_LID_CLOSED" -eq 1 ] && [ "$LID_CLOSED" -eq 0 ]; then
        LID_JUST_OPENED=1
    fi
    PREV_LID_CLOSED=$LID_CLOSED

    # --- Auto-reconnect if audio started playing OR lid just opened ---
    SHOULD_RECONNECT=0
    RECONNECT_REASON=""
    if [ "$LID_CLOSED" -eq 0 ] && [ -f "$DISCONNECTED_FILE" ]; then
        if [ "$LID_JUST_OPENED" -eq 1 ]; then
            SHOULD_RECONNECT=1
            RECONNECT_REASON="lid opened"
        elif [ "$AUDIO_PLAYING" -eq 1 ]; then
            SHOULD_RECONNECT=1
            RECONNECT_REASON="audio started playing"
        fi
    fi

    if [ "$SHOULD_RECONNECT" -eq 1 ]; then
        RECONNECT_ADDR=$(cat "$DISCONNECTED_FILE" 2>/dev/null | head -1 | cut -d'|' -f1)
        RECONNECT_NAME=$(cat "$DISCONNECTED_FILE" 2>/dev/null | head -1 | cut -d'|' -f2)
        SAVED_VOL=$(cat "$DISCONNECTED_FILE" 2>/dev/null | head -1 | cut -d'|' -f3)

        if [ -n "$RECONNECT_ADDR" ]; then
            # NOTE: Check that the device isn't already connected (another device
            # may have connected it, or user reconnected manually)
            ALREADY_CONNECTED=$(blueutil --is-connected "$RECONNECT_ADDR" 2>/dev/null)
            if [ "$ALREADY_CONNECTED" != "1" ]; then
                log "Auto-reconnecting '$RECONNECT_NAME' ($RECONNECT_ADDR) — $RECONNECT_REASON"
                blueutil --connect "$RECONNECT_ADDR" 2>/dev/null
                # NOTE: Give macOS a moment to establish the audio stream,
                # then switch output to the reconnected device
                sleep 3
                SwitchAudioSource -s "$RECONNECT_NAME" -t output 2>/dev/null
                # NOTE: Restore volume that was saved before disconnect
                if [ -n "$SAVED_VOL" ]; then
                    osascript -e "set volume output volume $SAVED_VOL" 2>/dev/null
                fi
            fi
            rm -f "$DISCONNECTED_FILE"
            # NOTE: Reset idle timer so we don't immediately disconnect again
            date +%s > "$STATE_FILE"
        fi
        continue
    fi

    # --- Check each connected Bluetooth audio device for disconnect ---
    CONNECTED_AUDIO=$(get_connected_audio_devices)

    if [ -n "$CONNECTED_AUDIO" ]; then
        echo "$CONNECTED_AUDIO" | while IFS='|' read -r addr name; do
            [ -z "$addr" ] && continue

            SHOULD_DISCONNECT=false
            REASON=""

            if [ "$LID_CLOSED" -eq 1 ]; then
                SHOULD_DISCONNECT=true
                REASON="lid closed"
            elif [ "$AUDIO_PLAYING" -eq 0 ] && [ "$IDLE_SECS" -ge "$IDLE_TIMEOUT" ]; then
                SHOULD_DISCONNECT=true
                REASON="audio idle for ${IDLE_SECS}s (threshold: ${IDLE_TIMEOUT}s)"
            fi

            if [ "$SHOULD_DISCONNECT" = true ]; then
                log "Disconnecting '$name' ($addr) — $REASON"
                # NOTE: Save the device info and current volume so we can
                # auto-reconnect and restore volume later
                CURRENT_VOL=$(osascript -e 'output volume of (get volume settings)' 2>/dev/null)
                echo "$addr|$name|$CURRENT_VOL" > "$DISCONNECTED_FILE"
                blueutil --disconnect "$addr" 2>/dev/null
                # NOTE: After disconnect, audio falls back to laptop speakers.
                # Mute so nothing unexpectedly blasts from speakers.
                osascript -e 'set volume output volume 0' 2>/dev/null
            fi
        done
    fi
done
