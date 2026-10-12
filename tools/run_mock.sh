#!/bin/bash
# 语法/加载自检：用假 hs API 加载 init.lua，抓语法错误与顶层运行时错误。
# 故意把 HOME 指到临时目录，免得 mock 运行污染真实日志。
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LUA="${LUA:-$(command -v lua || echo /opt/homebrew/bin/lua)}"

if [ ! -x "$LUA" ]; then
  echo "需要 lua 做语法自检（brew install lua），或用 LUA=/path/to/lua 指定"
  exit 1
fi

export HOME=/tmp/wxguard-mock-run
rm -rf "$HOME"; mkdir -p "$HOME"
cd "$REPO" || exit 1

"$LUA" tools/mock_test.lua init.lua
