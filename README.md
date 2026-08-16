<p align="center">
  <h1 align="center">FocusBar</h1>
  <p align="center">极简 macOS 菜单栏专注倒计时器 · Minimal macOS menu bar focus timer</p>
</p>

## 简介

FocusBar 是一款极简的 macOS 菜单栏专注倒计时器：点击开始 → 专注倒计时 → 结束提醒。没有番茄钟的复杂循环，没有多余功能，只有**计时**和**通知**。

## 功能

- 🕐 菜单栏倒计时（开始后菜单栏实时显示剩余时间）
- 🔔 结束系统通知（含提示音）
- ⏱ 可调专注时长（1–180 分钟，默认 25 分钟）
- 🌐 中 / 英 / 韩三语
- 🧊 纯 SwiftUI 原生，零第三方依赖

## 构建

用 Xcode 打开 `FocusBar.xcodeproj`，选择 Signing Team 后运行；或命令行：

```sh
xcodebuild -project FocusBar.xcodeproj -scheme FocusBar build
```

## 项目结构

```
FocusBar/
├── FocusBar.xcodeproj
└── FocusBar/
    ├── App.swift            菜单栏状态项 + 入口
    ├── Timer.swift          倒计时核心逻辑
    ├── View.swift           popover 界面
    ├── Notifications.swift  系统通知
    ├── Info.plist
    ├── FocusBar.entitlements
    ├── Assets.xcassets      应用图标 / 菜单栏图标
    └── en·ko·zh-Hans.lproj  本地化
```

## 致谢

基于 [ivoronin/TomatoBar](https://github.com/ivoronin/TomatoBar)（MIT）精简改造而来。

## 许可

MIT
