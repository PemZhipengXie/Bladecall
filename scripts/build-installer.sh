#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# CLT 27 的 macOS 27 SDK 缺 SwiftUIMacros 插件，@State 编不过；本机有 26.x SDK 就固定用它。
if [[ -z "${SDKROOT:-}" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk ]]; then
  export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
fi

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
# 产物目录随构建系统变化（Swift 6.4 起是 out/Products/Release），写死旧路径会混进过期的 Intel 版。
X86_BIN="$(swift build -c release --product CompletionBell --triple x86_64-apple-macosx13.0 \
    --scratch-path "$ROOT/.build-x86_64" --show-bin-path)/CompletionBell"
NATIVE_BIN="$APP/Contents/MacOS/CompletionBell"
UNIVERSAL_BIN="$WORK/CompletionBell-universal"

rm -rf "$WORK"
mkdir -p "$WORK" "$PAYLOAD/Applications" "$DMG_STAGE"
/usr/bin/lipo -create "$NATIVE_BIN" "$X86_BIN" -output "$UNIVERSAL_BIN"

# 发出去的程序不能依赖构建机路径：资源包回退路径会在用户机器上启动即崩，
# 过期产物也会带着旧路径。任一架构命中即中止。
for arch in arm64 x86_64; do
  /usr/bin/lipo -thin "$arch" "$UNIVERSAL_BIN" -output "$WORK/CompletionBell-$arch"
  if /usr/bin/strings -a "$WORK/CompletionBell-$arch" | grep -E "/\.build[^/]*/|$ROOT"; then
    echo "$arch 切片含构建机路径，拒绝打包" >&2
    exit 1
  fi
done
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
