import AppKit
import AVFoundation
import SwiftUI

class FBTimer: ObservableObject {
    @AppStorage("focusLength") var focusLength = 90
    @AppStorage("showTimerInMenuBar") var showTimerInMenuBar = true

    @Published var timeLeftString: String = ""
    @Published var remainingSeconds: Double = 0

    private let notificationCenter = FBNotificationCenter()
    private var timer: DispatchSourceTimer?
    private var finishTime: Date?
    private let formatter = DateComponentsFormatter()
    private var soundPlayer: AVAudioPlayer?

    var isRunning: Bool { timer != nil }

    init() {
        formatter.unitsStyle = .positional
        formatter.allowedUnits = [.minute, .second]
        formatter.zeroFormattingBehavior = .pad
        updateTimeLeft()
    }

    func startStop() {
        isRunning ? stop() : start()
    }

    func start() {
        guard !isRunning else { return }
        let length = max(1, focusLength)
        // 开始提示音：>=60 分钟用声音 1（0.76），<60 分钟用声音 2（0.5）
        if length >= 60 {
            playSound(named: "focus-start-long", volume: 0.76)
        } else {
            playSound(named: "focus-start-short", volume: 0.5)
        }
        finishTime = Date().addingTimeInterval(TimeInterval(length * 60))
        startDispatchTimer()
        FBStatusItem.shared.setIcon(name: .running)
        updateTimeLeft()
    }

    func stop() {
        guard isRunning else { return }
        cancelTimer()
        finishTime = nil
        FBStatusItem.shared.setIcon(name: .idle)
        updateTimeLeft()
        // 打断提示音：暂停 / 打断 / 重置的瞬间播放
        playSound(named: "focus-interrupt", volume: 0.83)
    }

    func updateTimeLeft() {
        if isRunning, let end = finishTime, end > Date() {
            timeLeftString = formatter.string(from: Date(), to: end) ?? "--:--"
            remainingSeconds = max(0, end.timeIntervalSinceNow)
        } else {
            timeLeftString = formatter.string(from: TimeInterval(focusLength * 60)) ?? "--:--"
            remainingSeconds = 0
        }
        if isRunning, showTimerInMenuBar {
            FBStatusItem.shared.setTitle(title: timeLeftString)
        } else {
            FBStatusItem.shared.setTitle(title: nil)
        }
    }

    private func startDispatchTimer() {
        let queue = DispatchQueue(label: "FocusBar.Timer")
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: .seconds(1), leeway: .never)
        t.setEventHandler(handler: onTimerTick)
        t.setCancelHandler(handler: onTimerCancel)
        timer = t
        t.resume()
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
    }

    private func onTimerTick() {
        DispatchQueue.main.async { [weak self] in
            self?.handleTick()
        }
    }

    private func handleTick() {
        guard isRunning, let end = finishTime else { return }
        updateTimeLeft()
        if end.timeIntervalSince(Date()) <= 0 {
            finish()
        }
    }

    private func onTimerCancel() {
        DispatchQueue.main.async { [weak self] in
            self?.updateTimeLeft()
        }
    }

    private func finish() {
        cancelTimer()
        finishTime = nil
        FBStatusItem.shared.setIcon(name: .idle)
        updateTimeLeft()
        // 结束提示音：声音 3
        playSound(named: "focus-finish", volume: 0.65)
        notificationCenter.send(
            title: NSLocalizedString("FBTimer.finish.title", comment: "Focus finished title"),
            body: NSLocalizedString("FBTimer.finish.body", comment: "Focus finished body")
        )
    }

    private func playSound(named name: String, volume: Float = 1.0) {
        guard let url = Bundle.main.url(forResource: name, withExtension: "mp3") else {
            print("sound file not found: \(name)")
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = volume
            player.prepareToPlay()
            soundPlayer = player
            player.play()
        } catch {
            print("sound play error: \(error)")
        }
    }
}
