#!/bin/bash
# Install bt-audio-release: auto-disconnect BT headphones when idle,
# auto-reconnect when lid opens.

set -e

echo "Installing dependencies..."
brew install blueutil nowplaying-cli switchaudio-osx 2>/dev/null || true

echo "Building bt-kill-a2dp (Swift CLI)..."
cd bt-kill-a2dp && swift build -c release && cd ..
mkdir -p ~/.local/bin
cp bt-kill-a2dp/.build/release/bt-kill-a2dp ~/.local/bin/bt-kill-a2dp
chmod +x ~/.local/bin/bt-kill-a2dp

echo "Installing script..."
cp bt-audio-release.sh ~/.local/bin/bt-audio-release.sh
chmod +x ~/.local/bin/bt-audio-release.sh

echo "Installing LaunchAgent..."
# NOTE: Substitute HOMEDIR placeholder with actual home directory since
# LaunchAgents don't expand ~ or $HOME
sed "s|HOMEDIR|$HOME|g" com.user.bt-audio-release.plist > ~/Library/LaunchAgents/com.user.bt-audio-release.plist

echo "Loading LaunchAgent..."
launchctl unload ~/Library/LaunchAgents/com.user.bt-audio-release.plist 2>/dev/null || true
launchctl load ~/Library/LaunchAgents/com.user.bt-audio-release.plist

echo "Done! Logs at ~/.local/bt-audio-release.log"
echo "To uninstall: bash uninstall.sh"
