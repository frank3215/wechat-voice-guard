#!/bin/bash
# 构建一个可钉到 Dock / Launchpad 的启动器应用，并（可选）钉到 Dock。
#
#   ./tools/build_app.sh              # 只构建
#   ./tools/build_app.sh --pin-dock   # 构建并钉到 Dock
#
# 应用本体是个 .app 包（Info.plist + 一个 bash 脚本 + 自绘图标）。
# 双击 = 部署最新配置（若与已部署的不一致）+ 启动 Hammerspoon。
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$HOME/Applications/WeChat Voice Guard.app"
NAME="WeChat Voice Guard"

PIN=0
[ "${1:-}" = "--pin-dock" ] && PIN=1

# ── 1) 图标：没有就现画（源码可重建，不依赖任何设计素材）────────────────────
ICNS="$REPO/assets/AppIcon.icns"
if [ ! -f "$ICNS" ]; then
  echo "生成图标…"
  ( cd "$REPO" && xcrun swiftc -O tools/make_icon.swift -o /tmp/wxg_make_icon ) || exit 1
  /tmp/wxg_make_icon "$REPO/assets/AppIcon.iconset" || exit 1
  iconutil -c icns "$REPO/assets/AppIcon.iconset" -o "$ICNS" || exit 1
fi

# ── 2) 组装 .app ───────────────────────────────────────────────────────────
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" || exit 1
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns" || exit 1

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>local.wechat-voice-guard.launcher</string>
  <key>CFBundleExecutable</key><string>launch</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# 把 CLI 打进应用包内：macOS 不允许 GUI 启动的应用执行 ~/Downloads 里的文件
# （实测报 "Operation not permitted"、退出码 126），放包内才稳。
cp "$REPO/tools/wxguard.sh" "$APP/Contents/Resources/wxguard.sh" || exit 1
chmod 755 "$APP/Contents/Resources/wxguard.sh"

cat > "$APP/Contents/MacOS/launch" <<'LAUNCH'
#!/bin/bash
# WeChat Voice Guard 启动器（双击 / Dock 点击）
# 真正逻辑是包内那份 wxguard.sh（与仓库同源，构建时拷贝），改仓库后需重新构建本应用。
BUNDLE="$(cd "$(dirname "$0")/.." && pwd)"
export WXG_REPO="@@REPO@@"
exec "$BUNDLE/Resources/wxguard.sh" start
LAUNCH
# 引号 heredoc 不会展开变量，仓库路径用占位符替换进去
sed -i '' "s|@@REPO@@|$REPO|" "$APP/Contents/MacOS/launch"

chmod 755 "$APP/Contents/MacOS/launch"
touch "$APP"                      # 让 Finder/Dock 刷新图标缓存
echo "已构建：$APP"

# 必须注册到 LaunchServices：刚创建的 bundle 未注册时，`open` 会返回 0 却什么都不做
# （实测踩过：open exit=0、脚本没跑、日志无痕——典型的"假成功"）
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREG" ]; then
  "$LSREG" -f "$APP" >/dev/null && echo "已注册到 LaunchServices"
fi

# ── 3) 钉到 Dock ───────────────────────────────────────────────────────────
if [ "$PIN" = "1" ]; then
  # 注意：Dock 里存的是**百分号编码**的 file:// URL（WeChat%20Voice%20Guard），
  # 拿未编码的路径 grep 永远匹配不上 —— 实测因此钉进去三份重复条目。必须按编码后的串比对。
  if defaults read com.apple.dock persistent-apps 2>/dev/null | grep -qF "WeChat%20Voice%20Guard"; then
    echo "Dock 里已经有它了，跳过"
  else
    defaults write com.apple.dock persistent-apps -array-add \
      "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>$APP</string><key>_CFURLStringType</key><integer>0</integer></dict></dict></dict>" || exit 1
    echo "已写入 Dock 配置，重启 Dock…"
    killall Dock
    sleep 2
  fi
fi

echo
echo "用法：在 Dock / Launchpad / 访达里双击「${NAME}」"
echo "卸载：rm -rf \"$APP\"（并从 Dock 拖走）"
