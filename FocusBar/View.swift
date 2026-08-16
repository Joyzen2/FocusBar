import SwiftUI

struct FBPopoverView: View {
    @ObservedObject var timer = FBTimer()

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
    let stiff: CGFloat = 0.18
    let damp: CGFloat = 0.82
    let rise: CGFloat = 0.4

    var width: CGFloat = 1
    var hoverX: CGFloat?
    var isRunning = false
    var remainingSeconds: Double = 0

    var heights: [CGFloat]
    var vels: [CGFloat]
    /// 每根竖杠的独立噪声（正弦+噪声模式）
    private var noise: [CGFloat]
    private var noiseTarget: [CGFloat]
    private var lastDate: Date?

    /// 驱动重绘的帧计数
    @Published var frame = 0
    private var timer: Timer?

    init() {
        heights = Array(repeating: base, count: barMinutes.count)
        vels = Array(repeating: 0, count: barMinutes.count)
        noise = (0 ..< barMinutes.count).map { _ in CGFloat.random(in: 0 ... 1) }
        noiseTarget = (0 ..< barMinutes.count).map { _ in CGFloat.random(in: 0 ... 1) }
    }

    func startLoop() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopLoop() {
        timer?.invalidate()
        timer = nil
    }

    var span: CGFloat { width / CGFloat(barMinutes.count) }

    func x(forIndex i: Int) -> CGFloat { (CGFloat(i) + 0.5) * span }

    func minute(atX x: CGFloat) -> Int {
        let idx = Int(((x / span) - 0.5).rounded())
        let i = max(0, min(barMinutes.count - 1, idx))
        return barMinutes[i]
    }

    /// 唯一红线：剩余时间所在 5 分钟档位的右端（向上取整）
    func redIndex() -> Int {
        guard isRunning else { return -1 }
        let remMin = remainingSeconds / 60
        let redValue = min(120, max(barMinutes[0], Int((remMin / 5).rounded(.up)) * 5))
        return barMinutes.firstIndex(of: redValue) ?? -1
    }

    /// 正弦 + 每根竖杠独立平滑噪声（选定的舞动算法）
    private func waveValue(x: CGFloat, t: CGFloat, i: Int) -> CGFloat {
        let v = 0.45 * sin(x * 0.075 - t * 2.2) + 0.55 * (noise[i] * 2 - 1)
        return max(0, min(1, 0.5 + 0.5 * v))
    }

    func tick() {
        let now = Date()
        let dt = min(1.0 / 30.0, now.timeIntervalSince(lastDate ?? now))
        lastDate = now
        let k = CGFloat(dt * 60)
        let t = CGFloat(now.timeIntervalSinceReferenceDate)

        // 独立噪声随机游走
        for i in noise.indices {
            if Double.random(in: 0 ... 1) < dt * 1.2 {
                noiseTarget[i] = CGFloat.random(in: 0 ... 1)
            }
            noise[i] += (noiseTarget[i] - noise[i]) * CGFloat(dt * 1.6)
        }

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

            // 物理：上升平滑（无回弹），下落 spring（轻微回弹）
            if target > heights[i] + 0.1 {
                heights[i] += (target - heights[i]) * (1 - pow(1 - rise, k))
                vels[i] = 0
            } else if target < heights[i] - 0.1 {
                vels[i] += (target - heights[i]) * stiff * k
                vels[i] *= pow(damp, k)
                heights[i] += vels[i] * k
                if heights[i] < base - 0.1 && hoverX == nil && !isRunning {
                    heights[i] = base
                    vels[i] = 0
                }
            }
        }
        frame += 1
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

            GeometryReader { geo in
                animator.width = geo.size.width
                return Canvas { context, size in
                    drawBars(context: &context, size: size)
                }
            }
            .frame(height: 70)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    isHovering = true
                    animator.hoverX = location.x
                    hoverMinute = animator.minute(atX: location.x)
                case .ended:
                    isHovering = false
                    animator.hoverX = nil
                }
            }
            .gesture(
                SpatialTapGesture().onEnded { value in
                    onPick(animator.minute(atX: value.location.x))
                }
            )
            .onAppear {
                animator.startLoop()
                animator.isRunning = isRunning
                animator.remainingSeconds = remainingSeconds
            }
            .onDisappear {
                animator.stopLoop()
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

    private func drawBars(context: inout GraphicsContext, size: CGSize) {
        let bottom = size.height - 24
        let redIdx = animator.redIndex()

        for i in 0 ..< animator.barMinutes.count {
            let x = animator.x(forIndex: i)
            let h = animator.heights[i]
            var color = Color.primary
            var w: CGFloat = 2

            if isRunning && animator.hoverX == nil && i == redIdx {
                color = Color(red: 0.91, green: 0.23, blue: 0.16)
                w = 4
            } else if let hx = animator.hoverX, abs(x - hx) < animator.span * 0.75 {
                w = 4
            }

            let rect = CGRect(x: x - w / 2, y: bottom - h, width: w, height: h)
            context.fill(Path(rect), with: .color(color))
        }

        for m in tickLabels {
            if let i = animator.barMinutes.firstIndex(of: m) {
                let x = animator.x(forIndex: i)
                context.draw(
                    Text("\(m)")
                        .font(.system(size: 10))
                        .foregroundColor(Color.secondary),
                    at: CGPoint(x: x, y: size.height - 8),
                    anchor: .center
                )
            }
        }
    }
}
