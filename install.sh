#!/bin/bash
# 编译当前源码并替换 /Applications/FocusBar.app，然后重新启动。
# 之所以有这个脚本：改完源码忘记重装，会让你对着九天前的二进制debug。
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="FocusBar"
INSTALLED="/Applications/${APP_NAME}.app"
DERIVED=".build"
BUILT="${DERIVED}/Build/Products/Release/${APP_NAME}.app"

echo "▸ 编译 Release"
xcodebuild -project "${APP_NAME}.xcodeproj" -scheme "${APP_NAME}" \
           -configuration Release -derivedDataPath "${DERIVED}" build \
  | grep -E "error:|warning: .*\.swift|BUILD" || true

[ -d "${BUILT}" ] || { echo "✗ 没找到构建产物 ${BUILT}"; exit 1; }

# 记录旧版信息，装完好对比 —— 这样「到底装上没有」永远不用猜
if [ -d "${INSTALLED}" ]; then
  OLD_DATE=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "${INSTALLED}/Contents/MacOS/${APP_NAME}")
else
  OLD_DATE="（未安装）"
fi

if pgrep -x "${APP_NAME}" >/dev/null; then
  echo "▸ 退出正在运行的 ${APP_NAME}"
  osascript -e "quit app \"${APP_NAME}\"" 2>/dev/null || true
  for _ in $(seq 1 20); do
    pgrep -x "${APP_NAME}" >/dev/null || break
    sleep 0.25
  done
  pgrep -x "${APP_NAME}" >/dev/null && pkill -x "${APP_NAME}" || true
fi

echo "▸ 替换 ${INSTALLED}"
rm -rf "${INSTALLED}"
cp -R "${BUILT}" /Applications/

NEW_DATE=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "${INSTALLED}/Contents/MacOS/${APP_NAME}")

echo "▸ 启动"
open "${INSTALLED}"

echo
echo "  旧: ${OLD_DATE}"
echo "  新: ${NEW_DATE}"
codesign -dvvv "${INSTALLED}" 2>&1 | grep -E "Identifier=|Signature=|flags=" | sed 's/^/  /'
echo
echo "✓ 装好了。如果专注结束不弹通知，去 系统设置 → 通知 里重新打开 ${APP_NAME}"
echo "  （ad-hoc 重签名会改变 cdhash，macOS 偶尔会当成新 app）"
