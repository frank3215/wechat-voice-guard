#!/bin/bash
# 把 init.lua 部署到 Hammerspoon 并重启，然后打印状态。
#
# 注意：这里复制成真实文件而不是做符号链接——Hammerspoon 读 ~/Downloads 里的目标
# 会撞上 macOS 15 的 TCC 保护（日志写入被静默拒绝，现象是"配置像是没加载"）。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/init.lua"
DST="$HOME/.hammerspoon/init.lua"
LOGDIR="$HOME/Library/Logs/WeChatVoiceGuard"

APP="${HAMMERSPOON_APP:-}"
if [ -z "$APP" ]; then
  for cand in "$HOME/Applications/Hammerspoon.app" "/Applications/Hammerspoon.app"; do
    if [ -d "$cand" ]; then APP="$cand"; break; fi
  done
fi

if [ -z "$APP" ]; then
  echo "找不到 Hammerspoon.app。请先安装："
  echo "  brew install --cask hammerspoon --appdir=\"\$HOME/Applications\""
  echo "或用 HAMMERSPOON_APP=/path/to/Hammerspoon.app ./deploy.sh 指定路径"
  exit 1
fi

EXEC="$APP/Contents/MacOS/Hammerspoon"
mkdir -p "$HOME/.hammerspoon" "$LOGDIR" || exit 1
rm -f "$DST"
cp "$SRC" "$DST" || exit 1
echo "已部署：$DST"
echo "日志目录：$LOGDIR"

# 精准定位 Hammerspoon 进程：只认 bundle 内的可执行文件路径，不做模糊匹配
PID="$(pgrep -f "$EXEC" || true)"
if [ -n "$PID" ]; then
  echo "重启 Hammerspoon (pid=$PID)"
  kill "$PID" 2>/dev/null
  for _ in $(seq 1 20); do
    sleep 0.3
    pgrep -f "$EXEC" >/dev/null || break
  done
fi

open -a "$APP" || exit 1
sleep 6

echo
echo "=== capture.log ==="
tail -30 "$LOGDIR/capture.log" 2>/dev/null || echo "(仍未生成：检查辅助功能权限)"
