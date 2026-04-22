#!/bin/bash
#
# bt-audio-release.sh
# Releases Bluetooth audio stream when idle so other devices can use the headphones.
#
# When idle: switches output to speakers, briefly disconnects/reconnects the BT
# device to free the audio profile, and keeps speakers selected.
# When lid closed: fully disconnects BT.
# When audio resumes / lid opens: reconnects if needed, but keeps the current
# output unless AUTO_SWITCH_TO_BT_ON_ACTIVITY=1.
#
# Dependencies: blueutil, nowplaying-cli, SwitchAudioSource (all via Homebrew)
#               bt-kill-a2dp (Swift CLI at ~/.local/bin/bt-kill-a2dp)

IDLE_TIMEOUT="${BT_AUDIO_IDLE_TIMEOUT:-300}"      # seconds of silence before releasing
POLL_INTERVAL="${BT_AUDIO_POLL_INTERVAL:-15}"     # seconds between checks
IDLE_POLLS_BEFORE_RELEASE="${BT_AUDIO_IDLE_POLLS_BEFORE_RELEASE:-2}"
IDLE_RECONNECT_DELAY="${BT_AUDIO_IDLE_RECONNECT_DELAY:-2}"
IDLE_RECONNECT_SETTLE="${BT_AUDIO_IDLE_RECONNECT_SETTLE:-4}"
AUTO_SWITCH_TO_BT_ON_ACTIVITY="${BT_AUDIO_AUTO_SWITCH_TO_BT_ON_ACTIVITY:-0}"
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
# NOTE: Require consecutive idle polls before releasing. Guards against a
# single poll missing audio detection (CoreAudio's IsRunningSomewhere can be
# briefly false during buffering/silence, and pmset output assertions don't
# fire for every source) right as the idle timer crosses the threshold.
IDLE_STREAK=0
log "Started bt-audio-release daemon (idle_timeout=${IDLE_TIMEOUT}s, poll=${POLL_INTERVAL}s, reconnect_delay=${IDLE_RECONNECT_DELAY}s, reconnect_settle=${IDLE_RECONNECT_SETTLE}s, auto_switch=${AUTO_SWITCH_TO_BT_ON_ACTIVITY})"

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

    # NOTE: When BT is disconnected, bt-kill-a2dp --is-active (above) can't
    # detect audio — it only checks connected BT devices. pmset assertions
    # don't fire for many apps/browsers. Fall back to nowplaying-cli when
    # we're in a released/disconnected state and haven't detected audio yet.
    # False positives (paused video tab with playbackRate=1) just mean we
    # reconnect eagerly — that's the better failure mode vs. never reconnecting.
    if [ "$AUDIO_PLAYING" -eq 0 ] && { [ -f "$RELEASED_FILE" ] || [ -f "$DISCONNECTED_FILE" ]; }; then
        PLAYBACK_RATE=$(nowplaying-cli get playbackRate 2>/dev/null)
        if [ "$PLAYBACK_RATE" = "1" ]; then
            AUDIO_PLAYING=1
            date +%s > "$STATE_FILE"
        fi
    fi

    LAST_PLAYING=$(cat "$STATE_FILE" 2>/dev/null || date +%s)
    NOW=$(date +%s)
    IDLE_SECS=$((NOW - LAST_PLAYING))

    # NOTE: Track consecutive idle polls so a single detection miss can't
    # trigger a release right as IDLE_SECS tips past IDLE_TIMEOUT.
    if [ "$AUDIO_PLAYING" -eq 1 ]; then
        IDLE_STREAK=0
    else
        IDLE_STREAK=$((IDLE_STREAK + 1))
    fi

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

    # --- Reconnect after lid open or real audio playing ---
    # NOTE: AUDIO_PLAYING is now based on CoreAudio active IO (not nowplaying-cli),
    # so this only triggers when actual audio data is flowing - not for phantom
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
                # NOTE: Verify the connect actually succeeded before switching
                # output and cleaning up state files. If it failed (headphones
                # out of range, connected to phone, BT profile timeout), we
                # must keep the state files so the next poll retries. Without
                # this check, a failed connect cleaned up state and the script
                # forgot it needed to reconnect — headphones stayed disconnected.
                CONNECT_OK=$(blueutil --is-connected "$RESTORE_ADDR" 2>/dev/null)
                if [ "$CONNECT_OK" != "1" ]; then
                    log "Reconnect to '$RESTORE_NAME' failed — will retry next poll"
                    continue
                fi
            fi

            if [ "$AUTO_SWITCH_TO_BT_ON_ACTIVITY" -eq 1 ]; then
                log "Switching output to '$RESTORE_NAME' - $RESTORE_REASON"
                SwitchAudioSource -s "$RESTORE_NAME" -t output 2>/dev/null
                # NOTE: Restore volume that was saved before release/disconnect
                if [ -n "$SAVED_VOL" ]; then
                    osascript -e "set volume output volume $SAVED_VOL" 2>/dev/null
                fi
            else
                CURRENT_OUTPUT_AFTER_RECONNECT=$(SwitchAudioSource -c -t output 2>/dev/null)
                if [ "$CURRENT_OUTPUT_AFTER_RECONNECT" = "$RESTORE_NAME" ]; then
                    log "Keeping output on '$BUILTIN_SPEAKERS' after reconnecting '$RESTORE_NAME' - $RESTORE_REASON"
                    SwitchAudioSource -s "$BUILTIN_SPEAKERS" -t output 2>/dev/null
                    osascript -e 'set volume output volume 0' 2>/dev/null
                else
                    log "Reconnected '$RESTORE_NAME' without switching output - $RESTORE_REASON"
                fi
            fi
            rm -f "$RELEASED_FILE" "$DISCONNECTED_FILE"
            # NOTE: Reset idle timer so we don't immediately release again
            date +%s > "$STATE_FILE"
        fi
        continue
    fi

    # --- Idle audio: switch output to speakers (release A2DP stream) ---
    if [ "$AUDIO_PLAYING" -eq 0 ] && [ "$IDLE_SECS" -ge "$IDLE_TIMEOUT" ] && [ "$IDLE_STREAK" -ge "$IDLE_POLLS_BEFORE_RELEASE" ] && [ "$LID_CLOSED" -eq 0 ]; then
        # Only act if current output is a BT audio device
        CONNECTED_AUDIO=$(get_connected_audio_devices)
        if [ -n "$CONNECTED_AUDIO" ]; then
            echo "$CONNECTED_AUDIO" | while IFS='|' read -r addr name; do
                [ -z "$addr" ] && continue
                # NOTE: Only release if this BT device is the current output
                if [ "$CURRENT_OUTPUT" = "$name" ]; then
                    CURRENT_VOL=$(osascript -e 'output volume of (get volume settings)' 2>/dev/null)
                    echo "$addr|$name|$CURRENT_VOL" > "$DISCONNECTED_FILE"
                    log "Releasing audio stream from '$name' - idle for ${IDLE_SECS}s (switching to speakers)"
                    # NOTE: --mute is handled inside the binary right after the
                    # CoreAudio switch. Doing it externally via osascript races
                    # with the output device change and can mute the headphones.
                    "$HOME/.local/bin/bt-kill-a2dp" "$addr" --speakers "$BUILTIN_SPEAKERS" --mute >> "$LOG_FILE" 2>&1
                    # NOTE: Belt-and-suspenders mute AFTER bt-kill-a2dp returns.
                    # At this point output is already on speakers, so osascript
                    # will mute speakers (not headphones). Catches cases where
                    # bt-kill-a2dp's internal --mute didn't take effect.
                    osascript -e 'set volume output volume 0' 2>/dev/null

                    log "Disconnecting then reconnecting '$name' without restoring it as active output"
                    blueutil --disconnect "$addr" 2>/dev/null
                    sleep "$IDLE_RECONNECT_DELAY"
                    blueutil --connect "$addr" 2>/dev/null
                    sleep "$IDLE_RECONNECT_SETTLE"

                    RECONNECTED=$(blueutil --is-connected "$addr" 2>/dev/null)
                    if [ "$RECONNECTED" = "1" ]; then
                        CURRENT_OUTPUT_AFTER_BOUNCE=$(SwitchAudioSource -c -t output 2>/dev/null)
                        if [ "$CURRENT_OUTPUT_AFTER_BOUNCE" = "$name" ]; then
                            SwitchAudioSource -s "$BUILTIN_SPEAKERS" -t output 2>/dev/null
                            osascript -e 'set volume output volume 0' 2>/dev/null
                            log "Reconnected '$name' and forced output back to '$BUILTIN_SPEAKERS'"
                        else
                            log "Reconnected '$name' without switching output back"
                        fi
                        rm -f "$RELEASED_FILE" "$DISCONNECTED_FILE"
                        date +%s > "$STATE_FILE"
                    else
                        log "Reconnect to '$name' failed after idle release - will retry on lid open/audio"
                    fi
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
