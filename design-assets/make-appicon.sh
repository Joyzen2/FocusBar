#!/bin/bash
# 从 1024 母版重新生成 AppIcon.appiconset 的全部尺寸。
# 母版已经处理好了：白边裁掉、圆角外抠成透明、按苹果网格排版
# （图形占画布 0.805，和系统自带图标一致）。改图标只需要替换母版再跑这个。
set -euo pipefail

cd "$(dirname "$0")/.."

SRC="design-assets/app-icon-dark-1024.png"      # 换成 -light- 即可切浅色版
DEST="FocusBar/Assets.xcassets/AppIcon.appiconset"

[ -f "$SRC" ] || { echo "✗ 找不到母版 $SRC"; exit 1; }

# 母版必须带透明通道，否则装上去会是一张不透明的方块
if ! sips -g hasAlpha "$SRC" | grep -q "hasAlpha: yes"; then
  echo "✗ $SRC 没有 alpha 通道 —— 圆角外必须是透明的"
  exit 1
fi

gen() { sips -z "$2" "$2" "$SRC" --out "${DEST}/$1" >/dev/null; echo "   $1  (${2}px)"; }

echo "▸ 从 $SRC 生成图标"
gen icon_16x16.png       16
gen icon_16x16@2x.png    32
gen icon_32x32.png       32
gen icon_32x32@2x.png    64
gen icon_128x128.png    128
gen icon_128x128@2x.png 256
gen icon_256x256.png    256
gen icon_256x256@2x.png 512
gen icon_512x512.png    512
gen icon_512x512@2x.png 1024

echo "✓ 完成。跑 ./install.sh 装上去看效果"
