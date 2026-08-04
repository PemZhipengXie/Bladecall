#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

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
