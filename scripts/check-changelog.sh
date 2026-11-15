#!/bin/zsh
# 校验：当前 App 版本（Resources/Info.plist）在 CHANGELOG.md 里有带日期、非空的一节。
# 版本号改了却没写更新日志 → 退出码 1，CI 变红。
# 用法：scripts/check-changelog.sh            检查仓库里的版本
#       PLIST=/path/Info.plist CHANGELOG=/path/CHANGELOG.md scripts/check-changelog.sh   （测试用）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="${PLIST:-$ROOT/Resources/Info.plist}"
CHANGELOG="${CHANGELOG:-$ROOT/CHANGELOG.md}"

VERSION="$(sed -n '/<key>CFBundleShortVersionString<\/key>/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}' "$PLIST")"
[[ -n "$VERSION" ]] || { echo "读不到 $PLIST 的 CFBundleShortVersionString" >&2; exit 1; }

if ! grep -Eq "^## \[$VERSION\] - [0-9]{4}-[0-9]{2}-[0-9]{2}\$" "$CHANGELOG"; then
  echo "CHANGELOG 缺少版本 $VERSION：请添加 '## [$VERSION] - YYYY-MM-DD' 一节（新功能 / 改进 / 修复）" >&2
  exit 1
fi

CHANGELOG="$CHANGELOG" PLIST="$PLIST" "$ROOT/scripts/release-notes.sh" "$VERSION" >/dev/null
echo "CHANGELOG_CHECK=PASS ($VERSION)"
