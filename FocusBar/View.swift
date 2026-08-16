import SwiftUI

struct FBPopoverView: View {
    @ObservedObject var timer = FBTimer()
    @State private var buttonHovered = false

    private var startLabel = NSLocalizedString("FBPopoverView.start.label", comment: "Start")
    private var stopLabel = NSLocalizedString("FBPopoverView.stop.label", comment: "Stop")

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                timer.startStop()
                FBStatusItem.shared.closePopover(nil)
            } label: {
                Text(timer.isRunning
                     ? (buttonHovered ? stopLabel : timer.timeLeftString)
                     : startLabel)
                    .foregroundColor(Color.white)
                    .font(.system(.body).monospacedDigit())
                    .frame(maxWidth: .infinity)
            }
            .onHover { over in
                buttonHovered = over
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

            FocusDurationPicker(minutes: $timer.focusLength)

            Group {
                Button {
                    NSApplication.shared.terminate(self)
                } label: {
                    Text(NSLocalizedString("FBPopoverView.quit.label", comment: "Quit"))
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

/// 非线性专注时长选择器：滑块 10–120 + 刻度 30/60/90（38%/66%/88%）+ 末端无边框输入框
struct FocusDurationPicker: View {
    @Binding var minutes: Int

    private let minMinutes: Double = 1
    private let maxMinutes: Double = 120
    private let inputMax = 999
    private let segments: [(Double, Double)] = [
        (1, 0.0), (30, 0.38), (60, 0.66), (90, 0.88), (120, 1.0)
    ]
    private let tickValues: [Int] = [30, 60, 90]
    private let thumbSize: CGFloat = 18
    private let trackHeight: CGFloat = 8

    @State private var inputText: String = ""

    init(minutes: Binding<Int>) {
        self._minutes = minutes
        _inputText = State(initialValue: "\(minutes.wrappedValue)")
    }

    private func position(for value: Double) -> Double {
        for i in 0 ..< (segments.count - 1) {
            let (v0, p0) = segments[i]
            let (v1, p1) = segments[i + 1]
            if value >= v0 && value <= v1 {
                return p0 + (p1 - p0) * (value - v0) / (v1 - v0)
            }
        }
        return value <= minMinutes ? 0 : 1
    }

    private func value(forPosition p: Double) -> Double {
        let clamped = max(0, min(1, p))
        for i in 0 ..< (segments.count - 1) {
            let (v0, p0) = segments[i]
            let (v1, p1) = segments[i + 1]
            if clamped >= p0 && clamped <= p1 {
                return v0 + (v1 - v0) * (clamped - p0) / (p1 - p0)
            }
        }
        return clamped <= 0 ? minMinutes : maxMinutes
    }

    private func snap(_ v: Double) -> Int {
        Int(max(minMinutes, min(maxMinutes, (v / 5).rounded() * 5)))
    }

    private func commitInput() {
        if let v = Int(inputText), v > 0 {
            minutes = min(inputMax, max(Int(minMinutes), v))
        }
        inputText = "\(minutes)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(NSLocalizedString("FBPopoverView.focusLength.label", comment: "Focus length"))
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(minutes)")
                    .font(.title3.bold())
                    .foregroundColor(.accentColor)
                Text(NSLocalizedString("FBPopoverView.min", comment: "min"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 8) {
                GeometryReader { geo in
                    let w = geo.size.width
                    let usable = max(w - thumbSize, 1)
                    let sliderValue = min(Double(minutes), maxMinutes)
                    let p = position(for: sliderValue)
                    let thumbX = p * usable + thumbSize / 2

                    ZStack {
                        ForEach(tickValues, id: \.self) { v in
                            let x = position(for: Double(v)) * usable + thumbSize / 2
                            VStack(spacing: 3) {
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.45))
                                    .frame(width: 1.5, height: 6)
                                Text("\(v)")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            .position(x: x, y: 13)
                        }
                        Capsule()
                            .fill(Color.secondary.opacity(0.22))
                            .frame(height: trackHeight)
                            .position(x: w / 2, y: 37)
                        Circle()
                            .fill(Color.white)
                            .shadow(color: Color.black.opacity(0.3), radius: 3, y: 1)
                            .frame(width: thumbSize, height: thumbSize)
                            .position(x: thumbX, y: 37)
                    }
                    .frame(height: 46)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { g in
                                let x = min(max(g.location.x, thumbSize / 2), w - thumbSize / 2)
                                minutes = snap(value(forPosition: (x - thumbSize / 2) / usable))
                            }
                    )
                }
                .frame(height: 46)

                HStack(spacing: 1) {
                    TextField("", text: $inputText)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.center)
                        .frame(width: 42)
                        .font(.system(size: 15, weight: .semibold))
                        .onSubmit { commitInput() }
                        .onChange(of: inputText) { newValue in
                            let filtered = String(newValue.filter { $0.isNumber }.prefix(3))
                            if filtered != newValue {
                                inputText = filtered
                            }
                        }
                    Text(NSLocalizedString("FBPopoverView.min", comment: "min"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .onChange(of: minutes) { newValue in
            inputText = "\(newValue)"
        }
    }
}
