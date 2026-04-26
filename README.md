# bt-audio-release

Auto-disconnect Bluetooth headphones from your Mac when idle, so other devices (phone, iPad, etc.) can use them. Reconnect the BT link when you start playing audio again or open the lid, without switching Mac output back to the headphones unless configured to do so.

I use this with my Bose NC 700 headphones. They don't support multipoint audio (only one device can stream A2DP at a time), so when connected to my MacBook, my phone can't use them — even if nothing is playing on the Mac. The Mac holds the audio stream open indefinitely. This script fixes that.

## What it does

- **Releases BT audio** after `BT_AUDIO_IDLE_TIMEOUT` seconds of silence (default 300s). It switches the Mac's output to speakers, briefly disconnects/reconnects the headphones to free the A2DP profile, then keeps speakers selected.
- **Disconnects immediately** when the lid is closed.
- **Mutes the laptop speakers** on release, so nothing blasts unexpectedly.
- **Auto-reconnects** the BT link when audio starts playing or the lid is reopened. Verifies the reconnect actually succeeded and retries on the next poll if it didn't.
- **Keeps current output by default** after reconnect. Set `BT_AUDIO_AUTO_SWITCH_TO_BT_ON_ACTIVITY=1` to switch output back to the headphones and restore the saved volume when activity resumes.
- **Two consecutive idle polls required** before releasing, so a single missed audio-detection poll can't trip a release right as `IDLE_SECS` tips past `IDLE_TIMEOUT`.
- **Manual headphone output switches reset the idle timer**, so choosing the headphones by hand is not immediately undone by an old idle timestamp.
- Runs as a background LaunchAgent (starts on login, auto-restarts if killed).

## Audio-playback detection

Audio is detected via three mechanisms, tried in order:

1. **`bt-kill-a2dp --is-active <addr>`** — reads CoreAudio's `kAudioDevicePropertyDeviceIsRunningSomewhere`. Authoritative when BT is connected, but only works against connected BT devices.
2. **`pmset -g assertions | grep com.apple.audio.*:output`** — catches Zoom/Meet/etc. that hold output assertions even when they aren't the CoreAudio default device.
3. **`nowplaying-cli get playbackRate`** (fallback, only when state files exist) — catches music/video/browser sessions when BT is disconnected and neither of the above fire. False positives here (e.g. a paused video tab that still reports `playbackRate=1`) cause an eager reconnect, which is the better failure mode vs. never reconnecting.

The three together still don't catch everything — see **Known issues** below.

## Install

```bash
git clone git@github.com:Divide-By-0/bt-audio-release.git
cd bt-audio-release
bash install.sh
```

`install.sh` does the following:
- `brew install blueutil nowplaying-cli switchaudio-osx`
- Builds the Swift CLI at `bt-kill-a2dp/` and copies the release binary to `~/.local/bin/bt-kill-a2dp`
- Copies `bt-audio-release.sh` to `~/.local/bin/bt-audio-release.sh`
- Substitutes `HOMEDIR` in `com.user.bt-audio-release.plist` and installs to `~/Library/LaunchAgents/`
- `launchctl load` the plist

## Uninstall

```bash
bash uninstall.sh
```

## Configuration

Set environment variables in the LaunchAgent, or edit `~/.local/bin/bt-audio-release.sh` (the installed copy, not the one in this repo) and then restart the daemon:

| Variable | Default | Meaning |
|---|---|---|
| `BT_AUDIO_IDLE_TIMEOUT` | `300` | Seconds of silence before releasing. |
| `BT_AUDIO_POLL_INTERVAL` | `15` | Seconds between checks. |
| `BT_AUDIO_IDLE_POLLS_BEFORE_RELEASE` | `2` | Consecutive idle polls required before release. |
| `BT_AUDIO_IDLE_RECONNECT_DELAY` | `2` | Seconds to wait between idle disconnect and reconnect. |
| `BT_AUDIO_IDLE_RECONNECT_SETTLE` | `4` | Seconds to wait after reconnect before checking whether macOS switched output back. |
| `BT_AUDIO_AUTO_SWITCH_TO_BT_ON_ACTIVITY` | `0` | `1` = switch output back to headphones and restore volume when audio/lid-open activity resumes. `0` = reconnect BT but preserve current output. |
| `BUILTIN_SPEAKERS` | `MacBook Air Speakers` | Exact name of the built-in speaker output as it appears in `SwitchAudioSource -a -t output`. Change this if you're on a MacBook Pro. |

## Finding and managing the running daemon

### Where things live on disk

| Path | Purpose |
|---|---|
| `~/.local/bin/bt-audio-release.sh` | The installed shell script (what the LaunchAgent actually runs). |
| `~/.local/bin/bt-kill-a2dp` | Swift CLI that talks to CoreAudio; handles `--is-active`, `--speakers`, `--force`, `--mute`. |
| `~/Library/LaunchAgents/com.*.bt-audio-release.plist` | The LaunchAgent that keeps the daemon alive. See the label note below. |
| `~/.local/bt-audio-release.log` | Main log (tail this to debug). |
| `~/.local/bt-audio-release-stderr.log` | Stderr from the LaunchAgent. |
| `/tmp/bt-audio-release-last-playing` | Unix timestamp of the last detected audio activity. |
| `/tmp/bt-audio-release-released` | `addr\|name\|vol` of a device whose output was switched away while BT stayed connected. |
| `/tmp/bt-audio-release-disconnected` | `addr\|name\|vol` of a device that was disconnected on lid-close, or during an idle release before reconnect succeeds. |
| `/tmp/bt-audio-release-playing` | Ephemeral signal file used to smuggle the audio-playing result out of a piped while-loop subshell. |

### LaunchAgent label

The plist in this repo uses the label `com.user.bt-audio-release`. My own machine has the installed plist under `com.aayush.bt-audio-release` (renamed manually at some point). **If you're Claude and I ask you to restart the daemon on this machine, use `com.aayush.bt-audio-release`.** For fresh installs from `install.sh` the label is `com.user.bt-audio-release`. Check which one is actually loaded with:

```bash
launchctl list | grep bt-audio
```

### Common commands

```bash
# Is it running? → shows PID and label
launchctl list | grep bt-audio

# Live log
tail -f ~/.local/bt-audio-release.log

# Stderr (rare, only if the script itself crashed)
tail -f ~/.local/bt-audio-release-stderr.log

# Restart after editing the installed script
launchctl kickstart -k gui/$(id -u)/com.aayush.bt-audio-release
# (or com.user.bt-audio-release for a fresh install)

# After editing bt-audio-release.sh in this repo, copy it over and restart:
cp bt-audio-release.sh ~/.local/bin/bt-audio-release.sh
chmod +x ~/.local/bin/bt-audio-release.sh
launchctl kickstart -k gui/$(id -u)/com.aayush.bt-audio-release

# Manual run (foreground, for debugging — kill the daemon first or you'll have two)
launchctl bootout gui/$(id -u)/com.aayush.bt-audio-release
bash ~/.local/bin/bt-audio-release.sh

# State inspection
cat /tmp/bt-audio-release-last-playing      # last audio timestamp
ls -l /tmp/bt-audio-release-{released,disconnected} 2>/dev/null

# Check current audio output
SwitchAudioSource -c -t output

# Check BT connection state for a specific device
blueutil --is-connected <MAC-ADDRESS>
```

## Fixes applied (history)

In chronological order, so someone reading the log/git history can find the commit that introduced each piece of behavior.

1. **Replaced `nowplaying-cli` with a CoreAudio active-IO check** for the primary idle detection. `nowplaying-cli` reports `playbackRate=1` for any media session, including a paused browser tab, which caused the script to never release.
2. **Added periodic status logging** so `tail -f` shows what the daemon thinks is happening on every poll.
3. **Restored auto-reconnect on audio playing** (previously only reconnected on lid-open).
4. **Fix: brief disconnect right after starting a video.** Two root causes:
   - With `BT_FORCE_RELEASE=1` the release path was fully disconnecting BT but only writing `RELEASED_FILE`. The restore path treats `RELEASED_FILE` as "just switch output" (skips `blueutil --connect`), so audio stayed on the laptop speakers until macOS auto-reconnected the headphones a few seconds later. Fixed by writing `DISCONNECTED_FILE` in the force path.
   - A single missed audio-detection poll could trip a release right as `IDLE_SECS` crossed `IDLE_TIMEOUT`. Fixed by requiring two consecutive idle polls (`IDLE_STREAK >= 2`).
5. **Fix: speakers not muted on release.** Added an explicit `osascript -e 'set volume output volume 0'` after `bt-kill-a2dp` returns. `bt-kill-a2dp --mute` handles it internally, but with `--force` it can disconnect BT before the mute applies. The post-call osascript is safe because the output has already been switched to speakers — we're muting speakers, not headphones.
6. **Fix: failed reconnects never retried.** After `blueutil --connect`, the script now verifies with `blueutil --is-connected`. If the connect failed (headphones out of range, connected to phone, BT profile timeout), it `continue`s without cleaning up state files, so the next poll tries again.
7. **Fix: audio undetected when BT is disconnected.** The primary CoreAudio check only works on *connected* BT devices. Once BT is disconnected, `pmset` assertions were the only signal, and they don't fire for many apps/browsers. Added a `nowplaying-cli get playbackRate` fallback — only consulted when a state file exists, so false positives just cause eager reconnects rather than preventing releases.
8. **Changed idle release to a disconnect/reconnect bounce.** The idle path now frees the A2DP profile, reconnects the BT link, and leaves Mac output on muted speakers by default. This lets the headphones remain connected while staying available to another device for audio.
9. **Fix: manual headphone selection being undone.** Switching output to the headphones by hand now resets the idle timer, and the reconnect path only preserves a prior non-BT output when this daemon actually initiated the reconnect.

## Known issues / open questions

These are things I haven't tracked down yet. If you're Claude working on this, **don't assume the fixes above have closed these** — they're separate from what we fixed.

1. **BT sometimes disconnects and doesn't reconnect.** Even with the `nowplaying-cli` fallback and the connect-verify retry, there are still cases where the headphones end up disconnected and stay that way until I manually reconnect. Hypotheses worth checking:
   - Some audio sources don't even trigger `nowplaying-cli playbackRate=1`. Possibly silent system notifications, WebRTC streams without a media session, or apps that bypass all three detection channels.
   - `blueutil --connect` may succeed at the LE link level but fail to establish the A2DP profile, and `blueutil --is-connected` might still return `1` in that state. Worth logging `blueutil --info` of the device on failed-sounding restores.
   - If the daemon was killed/restarted while the state files existed, startup clears them (line ~73: `rm -f "$RELEASED_FILE" "$DISCONNECTED_FILE"`). Anything in-flight is forgotten.
2. **Unexplained early disconnect: <20s of silence sometimes triggers a release.** I've had cases where audio stops, I'm about to play something else maybe 15–20s later, and the headphones are already disconnected. This *shouldn't* be possible given `BT_AUDIO_IDLE_TIMEOUT=300` and the `IDLE_STREAK >= 2` guard — `IDLE_SECS` is computed from `STATE_FILE`'s timestamp, not from the streak. Candidate causes to investigate:
   - Is the `date +%s > "$STATE_FILE"` inside the piped-while subshell (line ~104) actually landing reliably? File I/O should cross subshells, but if the subshell hits an error before the redirect completes, `STATE_FILE` would stay stale.
   - Is `bt-kill-a2dp --is-active` returning false during active playback for some apps? (E.g., brief IO gaps during video silence that last a full poll interval.)
   - Is something else — macOS itself, or bt-kill-a2dp's `--force` interacting with the phone's BT stack — causing the headphones to drop, and the daemon is blameless?
   - First thing to add when this recurs: log `IDLE_SECS`, `IDLE_STREAK`, `AUDIO_PLAYING`, and the `STATE_FILE` mtime on every release, and inspect after a repro.
3. **Plist label divergence.** The repo ships `com.user.bt-audio-release.plist` but my installed one is `com.aayush.bt-audio-release`. Fresh `install.sh` runs will write the former; if both exist, I may end up with two daemons. Consider consolidating after verifying which is loaded (`launchctl list | grep bt-audio`).
4. **`BUILTIN_SPEAKERS` is hard-coded to "MacBook Air Speakers".** Breaks on a Pro or external-display setup. Haven't auto-detected this because `SwitchAudioSource` doesn't have a clean "built-in" flag.

## Dependencies

Installed automatically by `install.sh`:
- [blueutil](https://github.com/toy/blueutil) — Bluetooth CLI
- [nowplaying-cli](https://github.com/kirtan-shah/nowplaying-cli) — Now Playing detection
- [switchaudio-osx](https://github.com/deweller/switchaudio-osx) — Audio output switching
- `bt-kill-a2dp` — Swift CLI in this repo (built by `install.sh`)
