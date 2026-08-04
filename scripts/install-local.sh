#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="$ROOT/dist/剑令.app"
TARGET_DIR="$HOME/Applications"
TARGET_APP="$TARGET_DIR/剑令.app"
TARGET_EXECUTABLE="$TARGET_APP/Contents/MacOS/CompletionBell"
LABEL="com.suifeng.completion-bell"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

if [[ ! -d "$SOURCE_APP" ]]; then
  "$ROOT/scripts/build-app.sh"
fi

pkill -x CompletionBell 2>/dev/null || true
mkdir -p "$TARGET_DIR"
rm -rf "$TARGET_APP"
rm -rf "$TARGET_DIR/完成铃.app"
ditto "$SOURCE_APP" "$TARGET_APP"

mkdir -p "$HOME/Library/LaunchAgents"
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
rm -f "$LAUNCH_AGENT"
plutil -create xml1 "$LAUNCH_AGENT"
/usr/libexec/PlistBuddy -c "Add :Label string $LABEL" "$LAUNCH_AGENT"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments array" "$LAUNCH_AGENT"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string $TARGET_EXECUTABLE" "$LAUNCH_AGENT"
/usr/libexec/PlistBuddy -c "Add :RunAtLoad bool true" "$LAUNCH_AGENT"
/usr/libexec/PlistBuddy -c "Add :ProcessType string Interactive" "$LAUNCH_AGENT"
if ! launchctl bootstrap "gui/$UID" "$LAUNCH_AGENT"; then
  "$TARGET_EXECUTABLE" >/dev/null 2>&1 &
fi

echo "$TARGET_APP"
echo "$LAUNCH_AGENT"
