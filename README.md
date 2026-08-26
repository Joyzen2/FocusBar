<p align="center">
  <h1 align="center">FocusBar</h1>
  <p align="center">极简 macOS 菜单栏专注倒计时器 · Minimal macOS menu bar focus timer</p>
</p>

## 简介

FocusBar 是一款极简的 macOS 菜单栏专注倒计时器：选时长 → 专注倒计时 → 结束提醒。没有番茄钟的复杂循环，没有多余功能。

它只在菜单栏里存在（`LSUIElement`），不占 Dock，不进 Cmd-Tab。

## 功能

- **音符竖杠时长选择器** —— 25 根竖杠对应 1、5、10 … 120 分钟。鼠标扫过时竖杠像琴键一样跟着抬起，并播放对应的钢琴音（C3 起的大调音阶）。点哪根就从哪根开始。
- **菜单栏倒计时** —— 开始后菜单栏显示带圆角边框的剩余时间胶囊。
- **波浪倒计时** —— popover 打开时，竖杠以行波形式舞动；一根红色竖杠标出剩余时间所在档位，随时间向左推进，右侧的杠收平。
- **分层提示音** —— 开始（≥60 分钟和 <60 分钟用不同音色）、打断、结束各有独立音效和音量。
- **结束系统通知**
- 中 / 英 / 韩三语
- 纯 SwiftUI 原生，零第三方依赖

## 环境要求

macOS 13.0 或更高。

## 构建与安装

改完代码用这个装，一条命令搞定编译、替换 `/Applications`、重启：

```sh
./install.sh
```

它会打印新旧二进制的日期。**这一步不要跳过** —— 只编译不安装的话，你 Cmd+空格 打开的还是旧版本，很容易对着几天前的二进制排查问题。

也可以用 Xcode 打开 `FocusBar.xcodeproj` 直接运行，或者：

```sh
xcodebuild -project FocusBar.xcodeproj -scheme FocusBar -configuration Release build
```

签名是 ad-hoc（`CODE_SIGN_IDENTITY = "-"`），不需要开发者账号。代价是每次重装 cdhash 都会变，macOS 偶尔会把它当成新 app 而重置通知权限 —— 如果结束时不弹通知了，去 系统设置 → 通知 里重新打开。

## 项目结构

```
FocusBar/
├── install.sh               编译 + 替换 /Applications + 重启
├── FocusBar.xcodeproj
├── design-assets/
│   ├── app-icon-{light,dark}-1024.png   图标母版（已抠透明圆角、按苹果网格排版）
│   ├── make-appicon.sh                  从母版重新生成 appiconset 全部尺寸
│   └── interrupt-sound-source.mp3
└── FocusBar/
    ├── App.swift            菜单栏状态项 + popover 宿主 + 时间胶囊绘制
    ├── Timer.swift          倒计时核心（用绝对结束时间，睡眠唤醒后不漂）
    ├── View.swift           popover 界面 + 竖杠物理动画 + 钢琴音
    ├── Notifications.swift  系统通知
    ├── piano/               25 个钢琴采样（16-bit 单声道 44.1kHz）
    ├── Assets.xcassets      应用图标 / 菜单栏图标（菜单栏图标含浅深两套）
    └── en·ko·zh-Hans.lproj  本地化
```

## 实现上几个值得一提的点

**倒计时用绝对结束时间而不是累加秒数**，所以合盖睡眠再唤醒不会漂。

**竖杠物理是一套二阶弹簧**，上升偏临界阻尼、下落偏欠阻尼，两者之间用 `tanh` 平滑过渡而不是 `if/else` 硬切 —— 硬切会在每次穿越目标值时把速度清零，肉眼看就是一顿一顿的。

**波形是多层互质频率的正弦叠加**，不是随机噪声。随机游走虽然位置连续，但速度不连续，每次重新抽签都会折一个角。

**渲染走 `TimelineView(.animation)`**，跟显示器刷新对齐，且只让画布子树重绘。画布单独抽成 `Equatable` 的 `BarCanvas`，挡住每秒倒计时对它的重算。

**暂停用 `NSPopover.willShowNotification` 而不是 `didShow`** —— 后者要等 popover 展开动画放完才发（实测晚 520ms），那段时间画面是静止的。

## 致谢

基于 [ivoronin/TomatoBar](https://github.com/ivoronin/TomatoBar)（MIT）精简改造而来。

## 许可

MIT
