import SwiftUI
import AVFoundation
import AppKit

/// 钢琴音：播放真实采样 wav（大调音阶 C3 起，25 个音）
final class PianoSynth: ObservableObject {
    private let noteNames = [
        "C3","D3","E3","F3","G3","A3","B3",
        "C4","D4","E4","F4","G4","A4","B4",
        "C5","D5","E5","F5","G5","A5","B5",
        "C6","D6","E6","F6"
    ]
    private var players: [AVAudioPlayer] = []

    init() {
        for name in noteNames {
            if let url = Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "piano"),
               let p = try? AVAudioPlayer(contentsOf: url) {
                p.prepareToPlay()
                players.append(p)
            }
        }
    }

    func play(barIndex: Int, volume: Float) {
        guard players.count == noteNames.count else { return }
        let p = players[barIndex % noteNames.count]
        p.volume = volume
        p.currentTime = 0
        p.play()
    }
}

struct FBPopoverView: View {
    @StateObject var timer = FBTimer()

    private var quitLabel = NSLocalizedString("FBPopoverView.quit.label", comment: "Quit")

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FocusDurationPicker(
                minutes: $timer.focusLength,
                isRunning: timer.isRunning,
                remainingSeconds: timer.remainingSeconds
            ) { picked in
                if timer.isRunning {
                    timer.stop()
                } else {
                    timer.focusLength = picked
                    timer.start()
                    FBStatusItem.shared.closePopover(nil)
                }
            }

            Group {
                Button {
                    NSApplication.shared.terminate(self)
                } label: {
                    Text(quitLabel)
                    Spacer()
                    Text("⌘ Q").foregroundColor(Color.gray)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("q")
            }
        }
        .padding(12)
    }
}

/// 音符竖杠刻度动画器（物理状态 + 波浪算法，跨帧保持）
final class BarAnimator: ObservableObject {
    /// 竖杠分钟列表：1, 5, 10, ..., 120（interval 5，最低 1）
    let barMinutes: [Int] = [1] + Array(stride(from: 5, through: 120, by: 5))

    let base: CGFloat = 7
    let peak: CGFloat = 44
    let sigma: CGFloat = 71
    let waveAmp: CGFloat = 20

    // 二阶弹簧：全程一套积分器，方向切换时不再清零速度
    /// 角频率，越大越跟手、越小越绵
    let omega: CGFloat = 28
    /// 上升阻尼比：1 = 临界阻尼，不过冲
    let zetaRise: CGFloat = 1.0
    /// 下落阻尼比：< 1 落到底时有轻微回弹
    let zetaFall: CGFloat = 0.6

    var width: CGFloat = 1
    var hoverX: CGFloat?
    var isRunning = false
    var remainingSeconds: Double = 0

    var heights: [CGFloat]
    var vels: [CGFloat]
    /// 每根竖杠的固定相位偏移：让多层正弦各自错开，一次性生成
    private let phase: [CGFloat]
    private var lastDate: Date?


    init() {
        heights = Array(repeating: base, count: barMinutes.count)
        vels = Array(repeating: 0, count: barMinutes.count)
        phase = (0 ..< barMinutes.count).map { _ in CGFloat.random(in: 0 ..< 2 * .pi) }
    }

    /// 暂停时清掉时钟，恢复时不会因为 lastDate 过期而跳一大步
    func pauseClock() {
        lastDate = nil
    }

    /// 画竖杠。放在这里而不是视图里，是为了让画布子树不依赖任何每秒变化的视图参数
    func draw(into context: inout GraphicsContext, size: CGSize) {
        let bottom = size.height - 24
        let redIdx = redIndex()

        for i in 0 ..< barMinutes.count {
            let x = self.x(forIndex: i)
            let h = heights[i]
            var color = Color.primary
            var w: CGFloat = 2

            if isRunning && hoverX == nil && i == redIdx {
                color = Color(red: 0.91, green: 0.23, blue: 0.16)
                w = 4
            } else if let hx = hoverX, abs(x - hx) < span * 0.75 {
                w = 4
            }

            context.fill(Path(CGRect(x: x - w / 2, y: bottom - h, width: w, height: h)),
                         with: .color(color))
        }
    }

    var span: CGFloat { width / CGFloat(barMinutes.count) }

    func x(forIndex i: Int) -> CGFloat { (CGFloat(i) + 0.5) * span }

    func minute(atX x: CGFloat) -> Int {
        return barMinutes[index(atX: x)]
    }

    func index(atX x: CGFloat) -> Int {
        // 布局完成前 width 可能为 0，此时 x / span 是 inf 或 NaN，Int(_:) 会 trap
        guard span > 0 else { return 0 }
        let raw = (x / span) - 0.5
        guard raw.isFinite else { return 0 }
        let idx = Int(raw.rounded())
        return max(0, min(barMinutes.count - 1, idx))
    }

    /// 唯一红线：剩余时间所在 5 分钟档位的右端（向上取整）
    func redIndex() -> Int {
        guard isRunning else { return -1 }
        let remMin = remainingSeconds / 60
        let redValue = min(120, max(barMinutes[0], Int((remMin / 5).rounded(.up)) * 5))
        return barMinutes.firstIndex(of: redValue) ?? -1
    }

    /// 横向行波 + 每根竖杠独立的多层正弦颤动
    /// 三层频率互不成比例，看起来随机但处处可导 —— 不会像随机游走那样每隔几百毫秒折一个角
    private func waveValue(x: CGFloat, t: CGFloat, i: Int) -> CGFloat {
        let p = phase[i]
        let travel = sin(x * 0.075 - t * 2.2)
        let flutter = 0.55 * sin(t * 1.70 + p)
                    + 0.30 * sin(t * 2.93 + p * 2.3)
                    + 0.15 * sin(t * 4.71 + p * 3.7)
        let v = 0.62 * travel + 0.38 * flutter
        return max(0, min(1, 0.5 + 0.5 * v))
    }

    /// 由 TimelineView 按显示器刷新节奏推进，date 用它给的时间戳而不是 Date()
    func advance(to now: Date) {
        let dt = min(1.0 / 30.0, now.timeIntervalSince(lastDate ?? now))
        lastDate = now
        let t = CGFloat(now.timeIntervalSinceReferenceDate)
        let h = CGFloat(dt)

        let redIdx = redIndex()
        let waveLimit = (isRunning && redIdx >= 0) ? barMinutes[redIdx] : 0

        for i in 0 ..< barMinutes.count {
            let x = self.x(forIndex: i)
            let minute = barMinutes[i]
            var target: CGFloat = base

            if isRunning && hoverX == nil {
                // 运行中（无 hover）：波浪区间含红线档位右端，右侧剁下去
                if minute <= waveLimit {
                    target = base + waveAmp * waveValue(x: x, t: t, i: i)
                } else {
                    target = base
                }
            } else if let hx = hoverX {
                // hover：自由扫动（高斯跳舞）
                let d = abs(x - hx)
                target = base + (peak - base) * exp(-(d * d) / (2 * sigma * sigma))
            } else {
                target = base
            }

            // 物理：一套二阶弹簧走到底。上升偏临界阻尼、下落偏欠阻尼的手感靠
            // 阻尼比在两者之间平滑过渡来保留，而不是 if/else 硬切 —— 硬切会在每次
            // 穿越 target 时把速度掐断，那正是肉眼看到的「卡一下」。
            let d = target - heights[i]
            let zeta = zetaFall + (zetaRise - zetaFall) * (0.5 + 0.5 * tanh(d * 1.5))
            let acc = omega * omega * d - 2 * zeta * omega * vels[i]
            vels[i] += acc * h
            heights[i] += vels[i] * h
            if heights[i] < 0 {
                heights[i] = 0
                vels[i] = 0
            }
        }
    }
}

/// 竖杠画布。刻意只吃 animator（无 @Published）和 paused 两个输入，配合 .equatable()
/// 挡住父视图每秒因倒计时触发的重算 —— 否则 TimelineView 会被连带重建，显示链调度
/// 要重新建立，表现出来就是每秒凝固一下。
private struct BarCanvas: View, Equatable {
    let animator: BarAnimator
    let paused: Bool
    let tickLabels: [Int]

    static func == (a: BarCanvas, b: BarCanvas) -> Bool {
        a.animator === b.animator && a.paused == b.paused && a.tickLabels == b.tickLabels
    }

    var body: some View {
        TimelineView(.animation(paused: paused)) { timeline in
            Canvas { context, size in
                animator.width = size.width
                animator.advance(to: timeline.date)
                animator.draw(into: &context, size: size)
            }
        }
        // 刻度标签是静态的，放在 overlay 里只排版一次，不跟着 60fps 重画
        .overlay {
            GeometryReader { geo in
                ForEach(tickLabels, id: \.self) { m in
                    if let i = animator.barMinutes.firstIndex(of: m) {
                        Text("\(m)")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .position(
                                x: (CGFloat(i) + 0.5) / CGFloat(animator.barMinutes.count) * geo.size.width,
                                y: geo.size.height - 8
                            )
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }
}

/// 音符竖杠刻度时长选择器：点击竖杠开始/停止 + 波浪倒计时 + 唯一红线
struct FocusDurationPicker: View {
    @Binding var minutes: Int
    var isRunning: Bool
    var remainingSeconds: Double
    var onPick: (Int) -> Void

    private let tickLabels: [Int] = [30, 60, 90]
    @StateObject private var animator = BarAnimator()
    @State private var isHovering = false
    @State private var hoverMinute = 0
    @StateObject private var piano = PianoSynth()
    @State private var lastPlayedIdx = -1
    @State private var popoverOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(NSLocalizedString("FBPopoverView.focusLength.label", comment: "Focus length"))
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                Spacer()
                Text(topText)
                    .font(topFont)
                    .foregroundColor(topColor)
                    .animation(.easeOut(duration: 0.12), value: isHovering)
                Text(NSLocalizedString("FBPopoverView.min", comment: "min"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            BarCanvas(animator: animator, paused: !popoverOpen, tickLabels: tickLabels)
                .equatable()
                .frame(height: 70)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    isHovering = true
                    animator.hoverX = location.x
                    hoverMinute = animator.minute(atX: location.x)
                    let idx = animator.index(atX: location.x)
                    if idx != lastPlayedIdx {
                        lastPlayedIdx = idx
                        piano.play(barIndex: idx, volume: 0.1)
                    }
                case .ended:
                    isHovering = false
                    animator.hoverX = nil
                    lastPlayedIdx = -1
                }
            }
            .gesture(
                SpatialTapGesture().onEnded { value in
                    onPick(animator.minute(atX: value.location.x))
                }
            )
            .onAppear {
                animator.isRunning = isRunning
                animator.remainingSeconds = remainingSeconds
            }
            .onDisappear {
                popoverOpen = false
                animator.pauseClock()
            }
            // .transient popover 关闭时不会触发 onDisappear，只能靠 NSPopover 通知来暂停，
            // 否则 TimelineView 会在 popover 关着的时候继续按刷新率空转
            .onReceive(NotificationCenter.default.publisher(for: NSPopover.didShowNotification)) { _ in
                animator.pauseClock()
                popoverOpen = true
            }
            .onReceive(NotificationCenter.default.publisher(for: NSPopover.didCloseNotification)) { _ in
                popoverOpen = false
                animator.pauseClock()
            }
            .onChange(of: isRunning) { newValue in
                animator.isRunning = newValue
            }
            .onChange(of: remainingSeconds) { newValue in
                animator.remainingSeconds = newValue
            }
        }
    }

    private var topText: String {
        if isRunning && !isHovering {
            let s = max(0, Int(ceil(remainingSeconds)))
            return String(format: "%d:%02d", s / 60, s % 60)
        }
        return "\(isHovering ? hoverMinute : minutes)"
    }

    private var topColor: Color {
        if isRunning && !isHovering {
            return Color(red: 0.91, green: 0.23, blue: 0.16)   // 番茄红（与菜单栏图标呼应）
        }
        return isHovering ? .primary : .accentColor
    }

    private var topFont: Font {
        (isHovering || isRunning) ? .title2.weight(.heavy) : .title3.bold()
    }

}
