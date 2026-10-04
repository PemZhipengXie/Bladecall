#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# CLT 27 的 macOS 27 SDK 缺 SwiftUIMacros 插件，@State 编不过；本机有 26.x SDK 就固定用它。
if [[ -z "${SDKROOT:-}" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk ]]; then
  export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
fi

# Bundle.module 找不到资源包会 fatalError（只认 .app 根目录和构建机路径），App 内禁用。
if grep -rnE '^[[:space:]]*[^/[:space:]].*Bundle\.module' "$ROOT/Sources/CompletionBell"; then
  echo "Sources/CompletionBell 不得使用 Bundle.module，改用 AppAssets.resourceURL" >&2
  exit 1
fi

swift run completion-bell-tests
SIMULATION="$(swift run -c release completion-bell-cli simulate)"
echo "$SIMULATION"
[[ "$SIMULATION" == "expected=10 detected=10 duplicate=0 history_replayed=0" ]]

swift run -c release completion-bell-cli doctor
swift run -c release completion-bell-cli scan
"$ROOT/scripts/build-app.sh"

for sound in sword-draw.mp3 sword-ring.m4a sword-sheath.mp3 sword-push.m4a swords-return.m4a; do
  SOURCE_SOUND="$ROOT/Sources/CompletionBell/Resources/Sounds/$sound"
  PACKAGED_SOUND="$ROOT/dist/剑令.app/Contents/Resources/Sounds/$sound"
  [[ -s "$SOURCE_SOUND" ]]
  [[ -s "$PACKAGED_SOUND" ]]
  afinfo "$SOURCE_SOUND" >/dev/null
  afinfo "$PACKAGED_SOUND" >/dev/null
done

echo "MVP_VERIFY=PASS"
