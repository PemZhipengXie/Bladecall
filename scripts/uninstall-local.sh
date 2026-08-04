#!/bin/zsh
set -euo pipefail

LABEL="com.suifeng.completion-bell"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
pkill -x CompletionBell 2>/dev/null || true
rm -f "$LAUNCH_AGENT"
rm -rf "$HOME/Applications/剑令.app" "$HOME/Applications/完成铃.app"

echo "剑令已从本机登录项和用户应用目录移除。"
