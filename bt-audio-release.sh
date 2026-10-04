#!/bin/bash
# Stable LaunchAgent entry point; policy and bounded commands live beside it.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
exec python3 "$(dirname "$0")/bt-audio-release.py" "$@"
