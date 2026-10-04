#!/bin/bash
# Install bt-audio-release: auto-disconnect BT headphones when idle,
# restore only headphones disconnected by lid closing.

set -e

echo "Installing dependencies..."
brew install blueutil switchaudio-osx python3

echo "Building bt-kill-a2dp (Swift CLI)..."
cd bt-kill-a2dp && swift build -c release && cd ..
mkdir -p ~/.local/bin
cp bt-kill-a2dp/.build/release/bt-kill-a2dp ~/.local/bin/bt-kill-a2dp
chmod +x ~/.local/bin/bt-kill-a2dp

echo "Installing script..."
cp bt-audio-release.sh bt-audio-release.py ~/.local/bin/
chmod +x ~/.local/bin/bt-audio-release.sh

echo "Installing LaunchAgent..."
# NOTE: Substitute HOMEDIR placeholder with actual home directory since
# LaunchAgents don't expand ~ or $HOME
sed "s|HOMEDIR|$HOME|g" com.user.bt-audio-release.plist > ~/Library/LaunchAgents/com.user.bt-audio-release.plist

echo "Loading LaunchAgent..."
# The migrated Air installation used a different label. Do not run both.
for label in com.aayush.bt-audio-release com.user.bt-audio-release; do
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
done
if [ -f ~/Library/LaunchAgents/com.aayush.bt-audio-release.plist ]; then
    mv ~/Library/LaunchAgents/com.aayush.bt-audio-release.plist \
       ~/Library/LaunchAgents/com.aayush.bt-audio-release.plist.disabled
fi
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.user.bt-audio-release.plist

echo "Done! Logs at ~/.local/bt-audio-release.log"
echo "To uninstall: bash uninstall.sh"
