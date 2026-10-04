#!/bin/bash
# Stable LaunchAgent entry point; policy and bounded commands live beside it.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
exec "$(dirname "$0")/bt-kill-a2dp" --daemon "$@"
