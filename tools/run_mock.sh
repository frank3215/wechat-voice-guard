#!/bin/bash
# 语法/加载自检：用假 hs API 加载 init.lua，抓语法错误与顶层运行时错误。
#
# 注意这个脚本只做「Lua 语法 + 顶层加载」检查，测不到任何真实行为
# （没有 macOS、没有微信、没有事件钩子）。它的价值只有一个：
# 改完 init.lua 后先跑一遍，别把一份语法坏掉的配置 deploy 出去——
# 那会让 Hammerspoon 静默变成一个什么都不做的空壳。
#
# 故意把 HOME 指到临时目录，免得 mock 运行污染真实日志（mock 会写 capture.log）。
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# LUA 可以是路径，也可以是命令名（如 LUA=lua5.4），统一解析成可执行路径
LUA_BIN=""
if [ -n "${LUA:-}" ]; then
  LUA_BIN="$(command -v "$LUA" 2>/dev/null || true)"
  if [ -z "$LUA_BIN" ] && [ -x "$LUA" ]; then LUA_BIN="$LUA"; fi
else
  for cand in lua lua5.4 lua5.3; do
    LUA_BIN="$(command -v "$cand" 2>/dev/null || true)"
    [ -n "$LUA_BIN" ] && break
  done
fi

if [ -z "$LUA_BIN" ]; then
  echo "需要 lua 做语法自检（macOS: brew install lua；Debian/Ubuntu: apt-get install lua5.4）"
  echo "也可以用 LUA=/path/to/lua 指定"
  exit 1
fi

echo "使用 lua: $LUA_BIN ($("$LUA_BIN" -v 2>&1 | head -1))"

export HOME=/tmp/wxguard-mock-run
rm -rf "$HOME"; mkdir -p "$HOME"
cd "$REPO" || exit 1

"$LUA_BIN" tools/mock_test.lua init.lua
