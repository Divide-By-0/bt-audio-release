# bt-audio-release

Release idle Bluetooth headphones so a phone can use them without the Mac repeatedly claiming their audio channel.

## Behavior

- After 300 seconds without active headset audio (and two idle polls), switch headset input/output to the Mac's built-in devices, mute speakers, and disconnect. **Do not reconnect after idle release.**
- When the lid closes, disconnect connected audio devices and record only successful disconnections.
- When the lid opens, make one reconnect attempt for each device this daemon disconnected **because the lid closed**. Keep the prior Mac output and built-in microphone. Notifications and playback never trigger a reconnect.
- Manual disconnections and idle releases do not create lid-open reconnect claims. Claims survive a daemon restart for up to 24 hours.
- Built-in audio devices are detected by CoreAudio transport type, so migration between MacBook Air and Pro does not depend on their names.
- Every external command has an eight-second deadline, including child processes. Bluetooth discovery and connection operations use the native helper. Unknown activity or failed routing checks leave the headset connected and log the failure.
- A process lock prevents duplicate daemons. Logs rotate at 1 MB with three backups.

This changes the automation's behavior; it cannot prevent macOS, another application, or another paired device from requesting a headset independently. Mac Bluetooth/CoreAudio logs can identify those requests.

## Install

```sh
bash install.sh
```

Requires Homebrew, Python 3, switchaudio-osx and Swift. The native helper remains the responsible startup process, using its existing macOS Bluetooth permission rather than requesting it for the Python interpreter. On a fresh install, allow the helper Bluetooth access when macOS asks. The installer builds the native helper, installs both daemon files, retires the migrated `com.aayush.bt-audio-release` job, and loads the canonical `com.user.bt-audio-release` job. `bash uninstall.sh` removes the canonical startup job.

## Configuration and diagnostics

Set environment variables in the LaunchAgent and reload it:

| Variable | Default | Meaning |
| --- | --- | --- |
| `BT_AUDIO_IDLE_TIMEOUT` | `300` | Idle seconds before release |
| `BT_AUDIO_POLL_INTERVAL` | `15` | Seconds between polls |
| `BT_AUDIO_IDLE_POLLS_BEFORE_RELEASE` | `2` | Consecutive verified idle polls |
| `BT_AUDIO_COMMAND_TIMEOUT` | `8` | Deadline per external command |
| `BT_AUDIO_SPEAKERS` | auto-detected | Optional exact speaker name override |

Old audio-activity reconnect and bounce options are no longer used. To use a headset after an idle release, connect it manually. A lid-open reconnect does not select its microphone or output for you.

Main log: `~/.local/bt-audio-release.log`. State and singleton lock: `~/.local/state/bt-audio-release/`. State contains only lid ownership and device identifiers, never call audio. Use `~/.local/bin/bt-audio-release.sh --once` for a single policy poll (it can release devices); a running daemon holds the lock and prevents a second copy.

```sh
python3 -m unittest discover -s tests -v
swift build -c release --package-path bt-kill-a2dp
```

Policy tests use fake device commands to cover idle/lid/manual ownership and command failure. They cannot verify a real phone call or headset multipoint behavior.
