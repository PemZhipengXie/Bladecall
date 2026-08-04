#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)"
APP="$ROOT/dist/剑令.app"
WORK="$ROOT/dist/.installer-work"
PAYLOAD="$WORK/payload"
PKG_SCRIPTS="$ROOT/packaging/scripts"
COMPONENT_PKG="$WORK/剑令-component.pkg"
FINAL_PKG="$ROOT/dist/剑令-$VERSION-build$BUILD-一键安装.pkg"
DMG_STAGE="$WORK/dmg"
FINAL_DMG="$ROOT/dist/剑令-$VERSION-build$BUILD-一键安装.dmg"

chmod +x "$PKG_SCRIPTS/preinstall" "$PKG_SCRIPTS/postinstall"

"$ROOT/scripts/verify-mvp.sh"
"$ROOT/scripts/build-app.sh"

# Build the Intel slice separately, then merge it with the native Apple-silicon
# release so the installer name and supported hardware stay truthful.
swift build \
    -c release \
    --product CompletionBell \
    --triple x86_64-apple-macosx13.0 \
    --scratch-path "$ROOT/.build-x86_64"
X86_BIN="$ROOT/.build-x86_64/x86_64-apple-macosx/release/CompletionBell"
NATIVE_BIN="$APP/Contents/MacOS/CompletionBell"
UNIVERSAL_BIN="$WORK/CompletionBell-universal"

rm -rf "$WORK"
mkdir -p "$WORK" "$PAYLOAD/Applications" "$DMG_STAGE"
/usr/bin/lipo -create "$NATIVE_BIN" "$X86_BIN" -output "$UNIVERSAL_BIN"
/usr/bin/install -m 755 "$UNIVERSAL_BIN" "$NATIVE_BIN"
/usr/bin/xattr -cr "$APP" 2>/dev/null || true
/usr/bin/codesign --force --deep --sign - "$APP"

COPYFILE_DISABLE=1 /usr/bin/ditto "$APP" "$PAYLOAD/Applications/剑令.app"
/usr/bin/pkgbuild \
    --root "$PAYLOAD" \
    --scripts "$PKG_SCRIPTS" \
    --identifier "com.suifeng.completion-bell.pkg" \
    --version "$VERSION" \
    --install-location / \
    "$COMPONENT_PKG"
/usr/bin/productbuild --package "$COMPONENT_PKG" "$FINAL_PKG"

COPYFILE_DISABLE=1 /usr/bin/ditto "$FINAL_PKG" "$DMG_STAGE/$(basename "$FINAL_PKG")"
COPYFILE_DISABLE=1 /usr/bin/ditto "$ROOT/packaging/安装说明.txt" "$DMG_STAGE/安装说明.txt"
/usr/bin/hdiutil create \
    -volname "剑令 $VERSION 一键安装" \
    -srcfolder "$DMG_STAGE" \
    -format UDZO \
    -ov \
    "$FINAL_DMG" >/dev/null

echo "$FINAL_PKG"
echo "$FINAL_DMG"
/usr/bin/lipo -archs "$APP/Contents/MacOS/CompletionBell"
/usr/bin/shasum -a 256 "$FINAL_PKG" "$FINAL_DMG"
