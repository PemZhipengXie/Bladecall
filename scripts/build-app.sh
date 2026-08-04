#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c release --product CompletionBell
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$ROOT/dist/剑令.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/CompletionBell" "$APP/Contents/MacOS/CompletionBell"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
ditto "$ROOT/Sources/CompletionBell/Resources" "$APP/Contents/Resources"
for bundle in "$BIN_DIR"/*.bundle; do
  [[ -d "$bundle" ]] || continue
  ditto "$bundle" "$APP/Contents/Resources/$(basename "$bundle")"
done
printf 'APPL????' > "$APP/Contents/PkgInfo"
xattr -cr "$APP" 2>/dev/null || true

# 稳定签名身份：ad-hoc 每次构建都会产生新身份，macOS 26 的菜单栏
# 许可等按签名记账的系统状态会随之失效。优先用本地证书签名；
# 一个都没有时才退回 ad-hoc。可用 JIANLING_SIGN_IDENTITY 覆盖。
IDENTITY="${JIANLING_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  for candidate in "Bladecall Local Signing" "Codex++ Local Signing"; do
    if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$candidate\""; then
      IDENTITY="$candidate"
      break
    fi
  done
fi
if [[ -n "$IDENTITY" ]]; then
  codesign --force --deep --sign "$IDENTITY" "$APP"
  echo "signed with: $IDENTITY"
else
  codesign --force --deep --sign - "$APP"
  echo "signed with: ad-hoc"
fi

echo "$APP"
