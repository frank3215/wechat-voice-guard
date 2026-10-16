#!/bin/bash
# wxguard —— WeChat Voice Guard 命令行入口
#
#   wxguard            查看状态（默认）
#   wxguard start      部署最新配置（若有变化）并启动
#   wxguard stop       停止
#   wxguard restart    重启（无条件重载配置）
#   wxguard status     状态：进程 / 开关 / 悬浮球 / 最近日志
#   wxguard log [-f]   看日志（-f 持续跟踪）
#   wxguard rescue     打开抢救箱（救回的语音文本）
#   wxguard install    把自己软链到 PATH（默认 ~/.local/bin）
#   wxguard uninstall  删除该软链
#
# Dock 上的「WeChat Voice Guard.app」只是本脚本 start 的一层薄壳，
# 所以两边逻辑永远一致，改这里就够了。
set -uo pipefail

# ── 解析自身路径（可能是软链，必须跟着跳）─────────────────────────────────
SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do
  LINK="$(readlink "$SELF")"
  case "$LINK" in
    /*) SELF="$LINK" ;;
    *)  SELF="$(dirname "$SELF")/$LINK" ;;
  esac
done
REPO="$(cd "$(dirname "$SELF")/.." && pwd)"

# 被 .app 调用时，本脚本是从应用包内执行的：macOS 不允许 GUI 启动的应用执行
# ~/Downloads 里的文件（会以 "Operation not permitted"、退出码 126 失败）。
# 所以启动器会设 WXG_REPO 指回真实仓库——它只用于"读最新配置"这类可选动作，
# 读不到就跳过，不影响启动。
REPO="${WXG_REPO:-$REPO}"

LOG="$HOME/Library/Logs/WeChatVoiceGuard"
CAPTURE="$LOG/capture.log"
CFG="$HOME/.hammerspoon/init.lua"
HS="$HOME/Applications/Hammerspoon.app"
[ -d "$HS" ] || HS="/Applications/Hammerspoon.app"
EXEC="$HS/Contents/MacOS/Hammerspoon"

hs_pid() { pgrep -f "$EXEC" 2>/dev/null || true; }
running() { [ -n "$(hs_pid)" ]; }

logline() {
  mkdir -p "$LOG"
  echo -e "$(date '+%Y-%m-%d %H:%M:%S')\t[cli] $*" >> "$CAPTURE"
}

ensure_hs() {
  if [ ! -d "$HS" ]; then
    echo "找不到 Hammerspoon.app。请先安装：" >&2
    echo "  brew install --cask hammerspoon --appdir=\"\$HOME/Applications\"" >&2
    return 1
  fi
}

deploy_cfg() {   # 返回 0 = 有变化，1 = 无变化
  [ -f "$REPO/init.lua" ] || return 1
  mkdir -p "$HOME/.hammerspoon"
  if [ -f "$CFG" ] && cmp -s "$REPO/init.lua" "$CFG"; then return 1; fi
  cp "$REPO/init.lua" "$CFG"
  return 0
}

cmd_start() {
  ensure_hs || exit 1
  local changed=0
  deploy_cfg && changed=1

  if running; then
    if [ "$changed" = "1" ]; then
      local pid; pid="$(hs_pid)"
      kill "$pid" 2>/dev/null
      for _ in $(seq 1 20); do sleep 0.3; running || break; done
      open -a "$HS"
      echo "配置有更新，已重启（pid=$pid → 新进程）"
      logline "start：配置有更新，已重启"
    else
      echo "已在运行（配置无变化，未重启）"
      logline "start：已在运行，配置无变化"
    fi
  else
    open -a "$HS"
    echo "已启动"
    logline "start：已拉起 Hammerspoon"
  fi
  sleep 1
  cmd_status
}

cmd_stop() {
  local pid; pid="$(hs_pid)"
  if [ -z "$pid" ]; then
    echo "本来就没在运行"
    return 0
  fi
  kill "$pid"
  for _ in $(seq 1 20); do sleep 0.3; running || break; done
  if running; then echo "⚠️ 仍在运行（pid=$(hs_pid)）" >&2; return 1; fi
  echo "已停止（捕获 / 自动续上 / 悬浮球全部停下）"
  logline "stop：已停止"
}

cmd_restart() {
  ensure_hs || exit 1
  cmd_stop >/dev/null 2>&1
  deploy_cfg >/dev/null 2>&1
  open -a "$HS"
  echo "已重启"
  logline "restart"
  sleep 1
  cmd_status
}

cmd_status() {
  echo "── WeChat Voice Guard ──────────────────────────"
  if running; then
    echo "  进程      : 运行中（pid=$(hs_pid)）"
  else
    echo "  进程      : 未运行  ← wxguard start 启动"
  fi
  local ar="未设置" ball="未设置"
  [ -f "$LOG/autoresume.state" ] && { [ "$(cat "$LOG/autoresume.state")" = "1" ] && ar="开" || ar="关"; }
  if [ -f "$LOG/ball.state" ]; then
    case "$(cut -d, -f3 "$LOG/ball.state" 2>/dev/null)" in
      1) ball="显示" ;; 0) ball="隐藏" ;; *) ball="未知" ;;
    esac
  fi
  echo "  自动续上  : $ar   悬浮球: $ball   拦截模式: 见 capture.log 里最近的 [mode]"
  echo "  配置      : $REPO/init.lua"
  if [ -f "$CFG" ]; then
    if cmp -s "$REPO/init.lua" "$CFG"; then echo "  已部署    : 与仓库一致"; else echo "  已部署    : ⚠️ 与仓库不一致（wxguard restart 生效）"; fi
  fi
  if [ -f "$CAPTURE" ]; then
    echo "  最近日志  :"
    tail -n 3 "$CAPTURE" | sed 's/^/    /'
  else
    echo "  最近日志  : 还没有（等第一次启动）"
  fi
  echo "  抢救箱    : $LOG/clipboard-rescue/"
}

cmd_log() {
  [ -f "$CAPTURE" ] || { echo "还没有日志：$CAPTURE" >&2; exit 1; }
  if [ "${1:-}" = "-f" ]; then tail -f "$CAPTURE"; else tail -n "${1:-40}" "$CAPTURE"; fi
}

cmd_rescue() {
  local d="$LOG/clipboard-rescue"
  [ -d "$d" ] || { echo "还没有抢救记录"; return 0; }
  ls -lt "$d" | sed 's/^/  /'
  echo
  echo "用 open \"$d\" 在访达里打开"
}

cmd_install() {
  local target=""
  for d in "$HOME/.local/bin" "$HOME/bin" /opt/homebrew/bin; do
    if [ -d "$d" ] && [ -w "$d" ]; then target="$d"; break; fi
  done
  if [ -z "$target" ]; then
    echo "找不到可写的 PATH 目录，请手动把 $REPO/tools/wxguard.sh 软链到你的 PATH 里" >&2
    exit 1
  fi
  ln -sf "$REPO/tools/wxguard.sh" "$target/wxguard"
  chmod +x "$REPO/tools/wxguard.sh"
  echo "已安装：$target/wxguard -> $REPO/tools/wxguard.sh"
  case ":$PATH:" in
    *":$target:"*) echo "新开终端即可直接用：wxguard status" ;;
    *) echo "⚠️ $target 不在当前 PATH 里，请把它加入 PATH（你的 ~/.zshrc 已有 ~/.local/bin 的话就没问题）" ;;
  esac
}

cmd_uninstall() {
  local removed=0
  for d in "$HOME/.local/bin" "$HOME/bin" /opt/homebrew/bin; do
    if [ -L "$d/wxguard" ]; then rm -f "$d/wxguard"; echo "已删除 $d/wxguard"; removed=1; fi
  done
  [ "$removed" = "0" ] && echo "没找到已安装的软链"
}

case "${1:-status}" in
  start)     shift; cmd_start "$@" ;;
  stop)      shift; cmd_stop "$@" ;;
  restart)   shift; cmd_restart "$@" ;;
  status)    shift; cmd_status "$@" ;;
  log)       shift; cmd_log "$@" ;;
  rescue)    shift; cmd_rescue "$@" ;;
  install)   shift; cmd_install "$@" ;;
  uninstall) shift; cmd_uninstall "$@" ;;
  -h|--help|help)
    sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
  *) echo "未知子命令：$1（试试 wxguard help）" >&2; exit 2 ;;
esac
