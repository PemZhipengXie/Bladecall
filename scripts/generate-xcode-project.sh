#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "未找到 XcodeGen。请先运行：brew install xcodegen" >&2
  exit 3
fi

xcodegen generate --spec project.yml
echo "已生成仅包含 macOS App 的公开工程。iPhone App 与 Widget 源码在独立私有仓库维护。" >&2
echo "$ROOT/Jianling.xcodeproj"
