#!/bin/bash
# Uninstall bt-audio-release

set -e

echo "Unloading LaunchAgent..."
launchctl unload ~/Library/LaunchAgents/com.user.bt-audio-release.plist 2>/dev/null || true

echo "Removing files..."
rm -f ~/Library/LaunchAgents/com.user.bt-audio-release.plist
rm -f ~/.local/bin/bt-audio-release.sh ~/.local/bin/bt-audio-release.py
rm -f ~/.local/bin/bt-kill-a2dp
rm -f ~/.local/bt-audio-release.log
rm -f ~/.local/bt-audio-release-stderr.log
rm -f /tmp/bt-audio-release-last-playing
rm -f /tmp/bt-audio-release-disconnected
rm -f /tmp/bt-audio-release-released

echo "Done! Dependencies (blueutil, switchaudio-osx) were not removed."
