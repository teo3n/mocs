#!/usr/bin/env bash
set -euo pipefail

LA_DIR="$HOME/Library/LaunchAgents"
PREFIX="${PREFIX:-$HOME/.local}"
UID_=$(id -u)

for label in com.user.mocsd com.user.hidutil-remap; do
    launchctl bootout "gui/$UID_/$label" 2>/dev/null || true
    rm -f "$LA_DIR/$label.plist"
done

rm -f "$PREFIX/bin/mocsd"

# clear HID mapping
/usr/bin/hidutil property --set '{"UserKeyMapping":[]}' >/dev/null

echo "reboot next"
