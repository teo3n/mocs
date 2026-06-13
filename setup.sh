#!/usr/bin/env bash

set -euo pipefail

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"

PREFIX="${PREFIX:-$HOME/.local}"
LA_DIR="$HOME/Library/LaunchAgents"
UID_=$(id -u)

echo "building"
make

echo "installing to $PREFIX/bin"
make install PREFIX="$PREFIX"

echo "applying hidutil remap"
/usr/bin/hidutil property --set \
  '{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0xFF00000003,"HIDKeyboardModifierMappingDst":0x7000000E0},{"HIDKeyboardModifierMappingSrc":0x7000000E0,"HIDKeyboardModifierMappingDst":0xFF00000003}]}' \
  >/dev/null

echo "installing LaunchAgents to $LA_DIR"
mkdir -p "$LA_DIR"

sed "s|__HOME__|$HOME|g" com.user.mocsd.plist > "$LA_DIR/com.user.mocsd.plist"
cp com.user.hidutil-remap.plist "$LA_DIR/com.user.hidutil-remap.plist"

echo "loading LaunchAgents"
for label in com.user.hidutil-remap com.user.mocsd; do
    launchctl bootout "gui/$UID_/$label" 2>/dev/null || true
    launchctl bootstrap "gui/$UID_" "$LA_DIR/$label.plist"
    launchctl enable "gui/$UID_/$label"
done

echo "done"
