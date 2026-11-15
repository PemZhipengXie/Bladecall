#!/bin/zsh
# 从 CHANGELOG.md 取出某个版本那一节，输出为 GitHub Release 说明。
# 用法：scripts/release-notes.sh [版本号]        默认取 Resources/Info.plist 里的版本
#       scripts/release-notes.sh 0.5.10 > notes.md
#       CHANGELOG=/path/to/CHANGELOG.md scripts/release-notes.sh 0.5.10
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHANGELOG="${CHANGELOG:-$ROOT/CHANGELOG.md}"
VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist" 2>/dev/null || sed -n '/CFBundleShortVersionString/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}' "$ROOT/Resources/Info.plist")}"
VERSION="${VERSION#v}"

[[ -f "$CHANGELOG" ]] || { echo "找不到 $CHANGELOG" >&2; exit 1; }

BODY="$(awk -v ver="$VERSION" '
  /^## \[/ {
    if (on) exit
    if (index($0, "## [" ver "]") == 1) { on = 1; next }
  }
  on { print }
' "$CHANGELOG" | sed -e :a -e '/^[[:space:]]*$/{$d;N;ba' -e '}' | sed '/./,$!d')"

if [[ -z "${BODY//[[:space:]]/}" ]]; then
  echo "CHANGELOG.md 里没有 $VERSION 的更新内容（需要 '## [$VERSION] - 日期' 一节且非空）" >&2
  exit 1
fi

printf '%s\n' "$BODY"
printf '\n完整历史见 [CHANGELOG.md](https://github.com/PemZhipengXie/Bladecall/blob/main/CHANGELOG.md)。\n'
