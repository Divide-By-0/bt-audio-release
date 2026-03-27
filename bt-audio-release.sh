#!/bin/bash
#
# bt-audio-release.sh
# Releases Bluetooth audio stream when idle so other devices can use the headphones.
# Auto-reconnects when audio starts playing or lid opens.
#
# When idle: switches output to speakers (releases A2DP stream), mutes speakers
# When lid closed: fully disconnects BT
# When audio resumes / lid opens: switches back to BT, restores volume
#
# Dependencies: blueutil, nowplaying-cli, SwitchAudioSource (all via Homebrew)
#               bt-kill-a2dp (Swift CLI at ~/.local/bin/bt-kill-a2dp)

IDLE_TIMEOUT=120       # seconds of silence before releasing
POLL_INTERVAL=15       # seconds between checks
# NOTE: Force mode fully disconnects BT when idle so multipoint headphones
# can route audio from the phone. Just switching the Mac's output only sends
# AVDTP SUSPEND (transport stays allocated), which isn't enough.
BT_FORCE_RELEASE=1
STATE_FILE="/tmp/bt-audio-release-last-playing"
RELEASED_FILE="/tmp/bt-audio-release-released"
DISCONNECTED_FILE="/tmp/bt-audio-release-disconnected"
LOG_FILE="$HOME/.local/bt-audio-release.log"
BUILTIN_SPEAKERS="MacBook Air Speakers"

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
# NOTE: Clear stale state files on startup so we don't auto-reconnect
# something the user manually changed before reboot
rm -f "$RELEASED_FILE" "$DISCONNECTED_FILE"
PREV_LID_CLOSED=0
log "Started bt-audio-release daemon (idle_timeout=${IDLE_TIMEOUT}s, poll=${POLL_INTERVAL}s)"

while true; do
    sleep "$POLL_INTERVAL"

    # --- Check lid state ---
    LID_CLOSED=0
    if ioreg -r -k AppleClamshellState -d 4 2>/dev/null | grep -q '"AppleClamshellState" = Yes'; then
        LID_CLOSED=1
    fi

    # --- Check if audio is actually playing ---
    # NOTE: We check CoreAudio directly (via bt-kill-a2dp --is-active) instead
    # of nowplaying-cli. nowplaying-cli reports playbackRate=1 for any media
    # session (e.g. a paused video tab) even when no audio is being output.
    # CoreAudio's kAudioDevicePropertyDeviceIsRunningSomewhere is authoritative.
    AUDIO_PLAYING=0

    # Check each connected BT audio device for active IO
    CONNECTED_FOR_CHECK=$(get_connected_audio_devices)
    if [ -n "$CONNECTED_FOR_CHECK" ]; then
        echo "$CONNECTED_FOR_CHECK" | while IFS='|' read -r addr name; do
            [ -z "$addr" ] && continue
            if "$HOME/.local/bin/bt-kill-a2dp" "$addr" --is-active 2>/dev/null; then
                date +%s > "$STATE_FILE"
                # NOTE: Signal to the outer shell via a temp file since this
                # runs in a subshell (piped while loop)
                touch /tmp/bt-audio-release-playing
            fi
        done
    fi
    if [ -f /tmp/bt-audio-release-playing ]; then
        AUDIO_PLAYING=1
        rm -f /tmp/bt-audio-release-playing
    fi

    # Also check pmset for active audio OUTPUT assertions (catches Zoom, Meet, etc.
    # that use audio but aren't the CoreAudio default output device)
    if pmset -g assertions 2>/dev/null | grep -q "com.apple.audio.*:output"; then
        AUDIO_PLAYING=1
        date +%s > "$STATE_FILE"
    fi

    LAST_PLAYING=$(cat "$STATE_FILE" 2>/dev/null || date +%s)
    NOW=$(date +%s)
    IDLE_SECS=$((NOW - LAST_PLAYING))

    # --- Get list of audio output device names (used by is_audio_device) ---
    AUDIO_OUTPUTS=$(SwitchAudioSource -a -t output 2>/dev/null)
    CURRENT_OUTPUT=$(SwitchAudioSource -c -t output 2>/dev/null)

    # Periodic status line so `tail -f` shows what's happening
    if [ "$AUDIO_PLAYING" -eq 1 ]; then
        log "status: audio active | output=$CURRENT_OUTPUT | lid=$([ "$LID_CLOSED" -eq 1 ] && echo closed || echo open)"
    else
        log "status: idle ${IDLE_SECS}s/${IDLE_TIMEOUT}s | output=$CURRENT_OUTPUT | lid=$([ "$LID_CLOSED" -eq 1 ] && echo closed || echo open)"
    fi

    # --- Detect lid just opened ---
    LID_JUST_OPENED=0
    if [ "$PREV_LID_CLOSED" -eq 1 ] && [ "$LID_CLOSED" -eq 0 ]; then
        LID_JUST_OPENED=1
    fi
    PREV_LID_CLOSED=$LID_CLOSED

    # --- Auto-restore: on lid open or real audio playing ---
    # NOTE: AUDIO_PLAYING is now based on CoreAudio active IO (not nowplaying-cli),
    # so this only triggers when actual audio data is flowing — not for phantom
    # media sessions like a paused video tab.
    SHOULD_RESTORE=0
    RESTORE_REASON=""
    if [ "$LID_CLOSED" -eq 0 ] && { [ -f "$RELEASED_FILE" ] || [ -f "$DISCONNECTED_FILE" ]; }; then
        if [ "$LID_JUST_OPENED" -eq 1 ]; then
            SHOULD_RESTORE=1
            RESTORE_REASON="lid opened"
        elif [ "$AUDIO_PLAYING" -eq 1 ]; then
            SHOULD_RESTORE=1
            RESTORE_REASON="audio started playing"
        fi
    fi

    if [ "$SHOULD_RESTORE" -eq 1 ]; then
        # NOTE: Prefer released file (just need output switch) over disconnected
        # file (need full BT reconnect). Use whichever exists.
        RESTORE_FILE=""
        NEEDS_BT_RECONNECT=0
        if [ -f "$RELEASED_FILE" ]; then
            RESTORE_FILE="$RELEASED_FILE"
        elif [ -f "$DISCONNECTED_FILE" ]; then
            RESTORE_FILE="$DISCONNECTED_FILE"
            NEEDS_BT_RECONNECT=1
        fi

        RESTORE_ADDR=$(cat "$RESTORE_FILE" 2>/dev/null | head -1 | cut -d'|' -f1)
        RESTORE_NAME=$(cat "$RESTORE_FILE" 2>/dev/null | head -1 | cut -d'|' -f2)
        SAVED_VOL=$(cat "$RESTORE_FILE" 2>/dev/null | head -1 | cut -d'|' -f3)

        if [ -n "$RESTORE_ADDR" ]; then
            if [ "$NEEDS_BT_RECONNECT" -eq 1 ]; then
                ALREADY_CONNECTED=$(blueutil --is-connected "$RESTORE_ADDR" 2>/dev/null)
                if [ "$ALREADY_CONNECTED" != "1" ]; then
                    log "Auto-reconnecting '$RESTORE_NAME' ($RESTORE_ADDR) — $RESTORE_REASON"
                    blueutil --connect "$RESTORE_ADDR" 2>/dev/null
                    # NOTE: Give macOS a moment to establish BT audio profile
                    sleep 3
                fi
            fi

            log "Switching output to '$RESTORE_NAME' — $RESTORE_REASON"
            SwitchAudioSource -s "$RESTORE_NAME" -t output 2>/dev/null
            # NOTE: Restore volume that was saved before release/disconnect
            if [ -n "$SAVED_VOL" ]; then
                osascript -e "set volume output volume $SAVED_VOL" 2>/dev/null
            fi
            rm -f "$RELEASED_FILE" "$DISCONNECTED_FILE"
            # NOTE: Reset idle timer so we don't immediately release again
            date +%s > "$STATE_FILE"
        fi
        continue
    fi

    # --- Idle audio: switch output to speakers (release A2DP stream) ---
    if [ "$AUDIO_PLAYING" -eq 0 ] && [ "$IDLE_SECS" -ge "$IDLE_TIMEOUT" ] && [ "$LID_CLOSED" -eq 0 ]; then
        # Only act if current output is a BT audio device
        CONNECTED_AUDIO=$(get_connected_audio_devices)
        if [ -n "$CONNECTED_AUDIO" ]; then
            echo "$CONNECTED_AUDIO" | while IFS='|' read -r addr name; do
                [ -z "$addr" ] && continue
                # NOTE: Only release if this BT device is the current output
                if [ "$CURRENT_OUTPUT" = "$name" ]; then
                    CURRENT_VOL=$(osascript -e 'output volume of (get volume settings)' 2>/dev/null)
                    echo "$addr|$name|$CURRENT_VOL" > "$RELEASED_FILE"
                    log "Releasing audio stream from '$name' — idle for ${IDLE_SECS}s (switching to speakers)"
                    FORCE_FLAG=""
                    if [ "$BT_FORCE_RELEASE" -eq 1 ]; then
                        FORCE_FLAG="--force"
                    fi
                    # NOTE: --mute is handled inside the binary right after the
                    # CoreAudio switch. Doing it externally via osascript races
                    # with the output device change and can mute the headphones.
                    "$HOME/.local/bin/bt-kill-a2dp" "$addr" --speakers "$BUILTIN_SPEAKERS" --mute $FORCE_FLAG >> "$LOG_FILE" 2>&1
                fi
            done
        fi
    fi

    # --- Lid closed: fully disconnect BT audio ---
    if [ "$LID_CLOSED" -eq 1 ]; then
        CONNECTED_AUDIO=$(get_connected_audio_devices)
        if [ -n "$CONNECTED_AUDIO" ]; then
            echo "$CONNECTED_AUDIO" | while IFS='|' read -r addr name; do
                [ -z "$addr" ] && continue
                CURRENT_VOL=$(osascript -e 'output volume of (get volume settings)' 2>/dev/null)
                echo "$addr|$name|$CURRENT_VOL" > "$DISCONNECTED_FILE"
                log "Disconnecting '$name' ($addr) — lid closed"
                blueutil --disconnect "$addr" 2>/dev/null
                osascript -e 'set volume output volume 0' 2>/dev/null
            done
        fi
        # NOTE: If we had a released (output-switched) device, promote it to
        # disconnected so lid-open triggers a full reconnect
        if [ -f "$RELEASED_FILE" ] && [ ! -f "$DISCONNECTED_FILE" ]; then
            RELEASED_ADDR=$(cat "$RELEASED_FILE" | head -1 | cut -d'|' -f1)
            if [ -n "$RELEASED_ADDR" ]; then
                mv "$RELEASED_FILE" "$DISCONNECTED_FILE"
                blueutil --disconnect "$RELEASED_ADDR" 2>/dev/null
                log "Disconnecting released device ($RELEASED_ADDR) — lid closed"
            fi
        fi
    fi
done
