# bt-audio-release

Auto-disconnect Bluetooth headphones from your Mac when idle, so other devices can use them.

I use this with my Bose NC 700 headphones. They don't support multipoint audio (only one device can stream A2DP at a time), so when connected to my MacBook, my phone can't use them — even if nothing is playing on the Mac. The Mac holds the audio stream open indefinitely.

This script fixes that by automatically disconnecting BT audio devices when idle, freeing them for my phone (or any other device). When I start playing audio on the Mac again or open the lid, it reconnects automatically.

## What it does

- **Disconnects** BT audio devices after 2 minutes of no audio playback
- **Disconnects immediately** when the lid is closed
- **Mutes laptop speakers** on disconnect (so nothing blasts unexpectedly)
- **Auto-reconnects** when audio starts playing or the lid is reopened
- **Restores volume** to what it was before disconnect
- Runs as a background LaunchAgent (starts on login, auto-restarts if killed)

## Detection

Audio playback is detected two ways:
1. `nowplaying-cli` — catches music, browser video, Spotify, etc.
2. `pmset -g assertions` — catches Zoom/Meet calls and other streams that don't report to Now Playing

## Install

```bash
git clone git@github.com:Divide-By-0/bt-audio-release.git
cd bt-audio-release
bash install.sh
```

## Uninstall

```bash
bash uninstall.sh
```

## Configuration

Edit `~/.local/bin/bt-audio-release.sh`:
- `IDLE_TIMEOUT=120` — seconds of silence before disconnect (default: 2 min)
- `POLL_INTERVAL=15` — seconds between checks

## Logs

```bash
tail -f ~/.local/bt-audio-release.log
```

## Dependencies

Installed automatically by `install.sh`:
- [blueutil](https://github.com/toy/blueutil) — Bluetooth CLI
- [nowplaying-cli](https://github.com/kirtan-shah/nowplaying-cli) — Now Playing detection
- [switchaudio-osx](https://github.com/deweller/switchaudio-osx) — Audio output switching
