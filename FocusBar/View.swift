import SwiftUI
import AVFoundation
import AppKit

/// 番茄红：菜单栏红线、顶部读数、结束按钮共用同一个色
let focusRed = Color(red: 0.91, green: 0.23, blue: 0.16)

/// 悬停琴键时的音量。
///
/// 单个音离削波很远（采样峰值 71%FS，这里再乘 0.16 只有 11%），真正的天花板是
/// 快速划过键盘时几十个音叠在一起：0.35 秒扫完 42 个键，合成峰值约 72%FS。
/// 再往上 0.19 就顶到 85%，0.22 基本贴着满刻度了。
let keyVolume: Float = 0.16

/// 钢琴音：C3–F6 共 42 个半音，**每一个都是单独录的真实采样**。
///
/// 采样来自 University of Iowa Electronic Music Studios（Steinway & Sons model B，
/// 2001 年录制），无授权限制。见 README。
///
/// 之前只有 25 个自然音，黑键靠 `AVAudioPlayer.rate = 2^(1/12)` 变速冒充升半音 ——
/// 音高是准的，但变速会把共振峰一起搬上去，低音区黑键听着发紧、尾巴还短 6%。
/// 现在黑键有了自己的录音，那套变速代码整个删掉了。
final class PianoSynth: ObservableObject {
    /// 半音号 0…41 对应 C3…F6。用降号是为了和 Iowa 的原始文件名对齐，便于溯源。
    static let noteNames: [String] = {
        let names = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]
        return (0 ..< 42).map { s in
            let midi = 48 + s                    // C3 = MIDI 48
            return names[midi % 12] + String(midi / 12 - 1)
        }
    }()

    private var players: [AVAudioPlayer?]

    init() {
        players = Self.noteNames.map { name in
            guard let url = Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "piano"),
                  let p = try? AVAudioPlayer(contentsOf: url) else { return nil }
            p.prepareToPlay()
            return p
        }
    }

    /// semitone：0…41，相对 C3。直接就是采样下标，不做任何变速或变调。
    func play(semitone: Int, volume: Float) {
        guard semitone >= 0, semitone < players.count,
              let player = players[semitone] else { return }
        player.volume = volume
        player.currentTime = 0
        player.play()
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

/// 钢琴键盘。C3–F6 的 25 个自然音 —— 正好对应 app 里 piano/ 下的 25 个采样 ——
/// 外加 17 个黑键。白键 j 对应 (j+1)*5 分钟，覆盖 5 到 125 分。
///
/// 黑键只作节奏地标和演奏用，点击一律落到它左侧的白键上：这台琴没有升降号采样，
/// 让黑键成为可选值会得到一个按下去没声音的档位。
final class BarAnimator: ObservableObject {

    // ── 几何 ────────────────────────────────────────────
    private static let naturals: Set<Int> = [0, 2, 4, 5, 7, 9, 11]
    /// 白键的半音号（相对 C3），25 个
    let whiteSemis: [Int]
    /// 黑键的半音号，17 个
    let blackSemis: [Int]
    /// 每个黑键落在第几个白键之后
    let blackAfter: [Int]

    var whiteCount: Int { whiteSemis.count }
    var keyCount: Int { whiteSemis.count + blackSemis.count }
    /// 键 id：0..<25 是白键，25..<42 是黑键
    func isBlack(_ k: Int) -> Bool { k >= whiteCount }
    func minutes(white j: Int) -> Int { (j + 1) * 5 }

    // ── 外观（设计工坊定稿的参数）───────────────────────
    let tiltDeg: CGFloat = 18
    let perspWhite: CGFloat = 330
    let perspBlack: CGFloat = 420
    let blackTiltMul: CGFloat = 1.45
    let shadowAlpha: CGFloat = 0.20
    let neighbour: CGFloat = 0.14
    let blackWRatio: CGFloat = 0.43
    let blackHRatio: CGFloat = 0.58
    let blackAlpha: CGFloat = 0.60
    let sepAlpha: CGFloat = 0.24
    /// 刻度数字去掉后，键区吃满整个高度
    let labelGutter: CGFloat = 0

    // ── 演奏 ────────────────────────────────────────────
    /// 行板。原来 132 是进行曲速度，古典织体在那个速度上糊成一片。
    let bpm: Double = 76
    /// 真人按和弦不可能绝对同时，几毫秒的错开最影响「像不像人弹的」
    let chordRoll: Double = 0.012

    // ── 按下的物理 ──────────────────────────────────────
    // 按下是手指驱动的，快而有力；松手之后键只靠自身配重回位，慢得多，
    // 最后撞在前档毡上停住。原来两个方向共用一条一阶滞后曲线
    // （press += (target-press)·dt·26），指数逼近永远到不了终点：
    // 按到 99% 要 176ms，真正归零要 290ms，其中 176ms 花在最后那 5% 的
    // 行程里 —— 那点距离肉眼看不出在动，但动画还没结束，所以收尾是
    // 「淡出」而不是「落定」。
    let omegaDown: CGFloat = 70
    let zetaDown: CGFloat = 0.88
    /// 手指是把键推过键床的。目标设在键床之下，键床才成为真正的硬停 ——
    /// 临界阻尼 + 目标正好落在键床上，只会渐近逼近，永远撞不到底。
    let overdrive: CGFloat = 0.18
    let omegaUp: CGFloat = 26
    let zetaUp: CGFloat = 0.58

    // ── 状态 ────────────────────────────────────────────
    /// popover 内容宽度（280 - padding 12*2）
    var width: CGFloat = 256
    /// 键盘条高度。改这一个数就够了，黑键长度、命中区、倾倒都是按比例算的。
    static let keyboardHeight: CGFloat = 62
    /// 最近一次绘制的画布尺寸，命中测试用
    private(set) var canvasSize = CGSize(width: 256, height: keyboardHeight)
    var hoverKey: Int?
    var isRunning = false
    var remainingSeconds: Double = 0

    private var press: [CGFloat]
    private var vel: [CGFloat]
    private var lastDate: Date?

    private struct Note { let t: Double; let dur: Double; let key: Int; let vel: CGFloat }
    private var notes: [Note] = []
    private var genUpTo: Double = 0
    private var clock: Double = 0

    // ── 乐曲状态 ────────────────────────────────────────
    /// 调、和声进行、织体每 8~16 小节换一次
    private var bar = 0
    private var sectionBars = 12
    private var keyIdx = 0
    private var progIdx = 0
    private var texture = 0
    private var sectionDyn: CGFloat = 0.75
    /// 旋律当前所在的音级（不是 MIDI）。用音级走才有级进，用 MIDI 走出来是噪声。
    private var melDeg = 21
    private var lastLeap = 0

    init() {
        var w: [Int] = [], b: [Int] = [], after: [Int] = []
        for s in 0 ... 41 {
            if Self.naturals.contains(s % 12) { w.append(s) }
            else { b.append(s); after.append(w.count) }
        }
        whiteSemis = w; blackSemis = b; blackAfter = after
        press = Array(repeating: 0, count: w.count + b.count)
        vel = Array(repeating: 0, count: w.count + b.count)
    }

    // ── 位置与命中 ──────────────────────────────────────
    var whiteW: CGFloat { width / CGFloat(whiteCount) }
    /// 键在横轴上的位置，用于邻键连带
    private func axis(_ k: Int) -> CGFloat {
        isBlack(k) ? CGFloat(blackAfter[k - whiteCount]) - 0.5 : CGFloat(k)
    }

    /// 命中测试：黑键压在白键上层且只占上 58%，所以先判黑键
    func key(at p: CGPoint, in size: CGSize) -> Int {
        guard size.width > 0, size.height > 0 else { return 0 }
        let fx = p.x / size.width
        let keyH = size.height - labelGutter
        let bw = blackWRatio / CGFloat(whiteCount)
        if keyH > 0, p.y <= keyH * blackHRatio {
            for (i, after) in blackAfter.enumerated() {
                if abs(fx - CGFloat(after) / CGFloat(whiteCount)) <= bw / 2 {
                    return whiteCount + i
                }
            }
        }
        return max(0, min(whiteCount - 1, Int(fx * CGFloat(whiteCount))))
    }

    /// 黑键归到左侧白键 —— 没有升降号采样，黑键不做可选值
    func whiteIndex(of k: Int) -> Int {
        isBlack(k) ? max(0, blackAfter[k - whiteCount] - 1) : k
    }
    func minutes(at p: CGPoint, in size: CGSize) -> Int {
        minutes(white: whiteIndex(of: key(at: p, in: size)))
    }
    func key(at p: CGPoint) -> Int { key(at: p, in: canvasSize) }
    func minutes(at p: CGPoint) -> Int { minutes(at: p, in: canvasSize) }
    /// 键号 → 半音号（相对 C3）。42 个采样按半音排列，这个值直接就是下标。
    func semitone(of k: Int) -> Int {
        isBlack(k) ? blackSemis[k - whiteCount] : whiteSemis[k]
    }

    // ── 时钟 ────────────────────────────────────────────
    func pauseClock() { lastDate = nil }

    /// popover 重开时把演奏推进到当前时刻，避免第一帧是一排静止的键
    func warmUp(to now: Date, seconds: Double = 1.2) {
        let step = 1.0 / 60.0
        var t = now.addingTimeInterval(-seconds)
        lastDate = t
        while t < now { t = t.addingTimeInterval(step); advance(to: t) }
        lastDate = nil
    }

    func advance(to now: Date) {
        let dt = max(0, min(1.0 / 30.0, now.timeIntervalSince(lastDate ?? now)))
        lastDate = now
        clock += dt

        if isRunning {
            let bar = 240.0 / bpm
            while genUpTo < clock + bar { generateBar(at: genUpTo); genUpTo += bar }
            notes.removeAll { clock - $0.t > $0.dur + 0.4 }
        } else if !notes.isEmpty {
            notes.removeAll()
            genUpTo = clock
        }

        // 目标按下量：演奏 + 悬停，再加邻键连带
        var target = [CGFloat](repeating: 0, count: keyCount)
        var drive = [CGFloat](repeating: 0, count: keyCount)
        func strike(_ k: Int, _ v: CGFloat, _ force: CGFloat) {
            guard v > 0, k >= 0, k < keyCount else { return }
            target[k] = max(target[k], v)
            drive[k] = max(drive[k], force)
            let x = axis(k)
            for o in 0 ..< keyCount where o != k {
                let d = abs(axis(o) - x)
                // 邻键连带是键床被压弯，不是被弹奏：只给深度，不给力度
                if d < 1.2 { target[o] = max(target[o], v * neighbour * (1 - d / 1.2)) }
            }
        }
        for n in notes { strike(n.key, envelope(clock - n.t, n.dur) * n.vel, n.vel) }
        if let h = hoverKey { strike(h, 1, 0.45) }

        // 定步长子积分。ω 到 70 时显式欧拉在 1/30 秒的步子上会发散，
        // 切成 1/360 秒的子步就稳了；42 个键 × 至多 12 子步，代价可以忽略。
        let sub = max(1, Int((dt / (1.0 / 360)).rounded(.up)))
        let h = CGFloat(dt) / CGFloat(sub)
        for _ in 0 ..< sub {
            for i in 0 ..< keyCount {
                let down = target[i] > press[i]
                let goal = down ? target[i] * (1 + overdrive * drive[i]) : target[i]
                // 轻触的键下落也慢 —— 真钢琴上力度只改速度，不改行程
                let w = down ? omegaDown * (0.55 + 0.45 * drive[i]) : omegaUp
                let z = down ? zetaDown : zetaUp
                vel[i] += (w * w * (goal - press[i]) - 2 * z * w * vel[i]) * h
                press[i] += vel[i] * h
                if down, press[i] >= target[i] {            // 键床：硬停，速度全吃掉
                    press[i] = target[i]; vel[i] = 0
                } else if !down, press[i] <= target[i] {    // 前档毡：键回不到静止位以上
                    press[i] = target[i]; vel[i] = 0
                }
                if press[i] < 0 { press[i] = 0; vel[i] = 0 }
            }
        }
    }

    /// 28ms 触底 → 按住整个音长 → 90ms 抬起。抬起比按下慢，符合手指离键。
    private func envelope(_ dt: Double, _ dur: Double) -> CGFloat {
        if dt < 0 { return 0 }
        if dt < 0.028 { return CGFloat(dt / 0.028) }
        if dt < dur { return 1 }
        let u = (dt - dur) / 0.09
        if u >= 1 { return 0 }
        return CGFloat(1 - u * u * (3 - 2 * u))
    }

    // ── 演奏：古典风格生成器 ─────────────────────────────
    //
    // 原来每个音符都要过一个把值钳在 0..<whiteCount 的函数，黑键（id 25…41）
    // 在数学上就够不着，所以整台琴只有白键在响；而且不在任何调上，是白键上的
    // 随机游走。现在按真正的古典写法来：
    //   ① 有调性 —— 挑带升降号的调，黑键是调号自带的，不是硬塞的
    //   ② 有功能和声 —— i-iv-V-i 这类进行，小调的 V 升七级（和声小调）
    //   ③ 有织体 —— 阿尔贝蒂低音 / 分解和弦 / 圆舞曲 / 圣咏 / 八度低音
    //
    // 音域只有 C3–F6（MIDI 48–89）三个半八度，比真钢琴窄得多，所以两手压得紧：
    // 左手 48–67，右手 65–89，越界的音按八度折回来。

    /// 带升降号的调。名字只是注释用，代码里只关心主音和调式。
    private static let musicKeys: [(root: Int, minor: Bool)] = [
        (0, true), (3, false), (5, true), (8, false), (7, true),
        (10, false), (2, true), (5, false), (6, true), (7, false),
    ]
    private static let majorSteps = [0, 2, 4, 5, 7, 9, 11]
    private static let minorSteps = [0, 2, 3, 5, 7, 8, 10]
    /// 功能和声进行，元素是级数（0 = I/i）
    private static let minorProgs: [[Int]] = [
        [0, 3, 4, 0], [0, 5, 3, 4], [0, 2, 6, 5, 1, 4, 0], [0, 4, 5, 3, 4, 0], [0, 5, 1, 4, 0],
    ]
    private static let majorProgs: [[Int]] = [
        [0, 5, 1, 4], [0, 3, 4, 0], [0, 5, 3, 4, 0], [0, 4, 5, 3, 0], [1, 4, 0, 4],
    ]

    private var musicKey: (root: Int, minor: Bool) { Self.musicKeys[keyIdx] }
    private var steps: [Int] { musicKey.minor ? Self.minorSteps : Self.majorSteps }
    private var prog: [Int] {
        musicKey.minor ? Self.minorProgs[progIdx] : Self.majorProgs[progIdx]
    }

    /// 音级 → MIDI。deg 0 = 主音在 C3 附近，每 7 级一个八度。
    private func midi(deg: Int, acc: Int = 0) -> Int {
        let o = Int(floor(Double(deg) / 7.0))
        let d = ((deg % 7) + 7) % 7
        return 48 + musicKey.root + steps[d] + 12 * o + acc
    }
    /// 小调的 V 和 vii 要升七级 —— 这个升音往往正好落在黑键上
    private func accidental(deg: Int, chord: Int) -> Int {
        (musicKey.minor && (chord == 4 || chord == 6) && ((deg % 7) + 7) % 7 == 6) ? 1 : 0
    }
    /// 把音级挪到最接近 target 的八度，并夹在 [lo, hi]
    private func fit(_ deg: Int, _ acc: Int, near target: Int, _ lo: Int, _ hi: Int) -> (deg: Int, midi: Int) {
        var d = deg, m = midi(deg: d, acc: acc)
        while m < target - 6 { d += 7; m = midi(deg: d, acc: acc) }
        while m > target + 6 { d -= 7; m = midi(deg: d, acc: acc) }
        while m < lo { d += 7; m = midi(deg: d, acc: acc) }
        while m > hi { d -= 7; m = midi(deg: d, acc: acc) }
        return (d, m)
    }

    private func newSection() {
        keyIdx = Int.random(in: 0 ..< Self.musicKeys.count)
        progIdx = Int.random(in: 0 ..< 5)
        texture = Int.random(in: 0 ..< 5)
        sectionBars = Int.random(in: 8 ... 16)
        sectionDyn = CGFloat.random(in: 0.55 ... 0.9)
    }

    private func generateBar(at t0: Double) {
        if bar % sectionBars == 0 && bar > 0 { newSection() }
        let beat = 60.0 / bpm
        let chord = prog[bar % prog.count]
        let triad = [chord, chord + 2, chord + 4]
        bar += 1

        // 乐句呼吸：句末渐弱，句首回来
        let dyn = sectionDyn * (1 - 0.18 * CGFloat(bar % 4) / 4)
        func roll() -> Double { Double.random(in: -chordRoll ... chordRoll) }
        func emit(_ m: Int, _ t: Double, _ dur: Double, _ v: CGFloat) {
            guard m >= 48, m <= 89 else { return }
            let semi = m - 48
            let k = Self.naturals.contains(semi % 12)
                ? whiteSemis.firstIndex(of: semi)
                : blackSemis.firstIndex(of: semi).map { whiteCount + $0 }
            guard let key = k else { return }
            notes.append(Note(t: t0 + t + roll(), dur: dur, key: key, vel: max(0.05, v * dyn)))
        }

        // ── 左手：全部压在 C3–G4，绝不越过右手 ──────────────
        let cm = triad.map { fit($0, accidental(deg: $0, chord: chord), near: 52, 48, 67).midi }.sorted()
        let root = cm[0]
        switch texture {
        case 0:                                     // 阿尔贝蒂低音：根-五-三-五
            let seq = [cm[0], cm[2], cm[1], cm[2]]
            for i in 0 ..< 8 {
                emit(seq[i % 4], Double(i) * beat / 2, beat * 0.55, .random(in: 0.30 ... 0.42))
            }
        case 1:                                     // 分解和弦
            let seq = [cm[0], cm[1], cm[2], cm[1]]
            for i in 0 ..< 8 {
                var m = seq[i % 4] + (i >= 4 ? 12 : 0)
                if m > 67 { m -= 12 }
                emit(m, Double(i) * beat / 2, beat * 0.7, .random(in: 0.28 ... 0.40))
            }
        case 2:                                     // 圆舞曲：低音 + 两下和弦
            emit(root, 0, beat * 0.9, .random(in: 0.42 ... 0.55))
            for b in [1, 2] {
                for m in cm {
                    emit(m > root ? m : (m + 12 <= 67 ? m + 12 : m),
                         Double(b) * beat, beat * 0.75, .random(in: 0.22 ... 0.32))
                }
            }
        case 3:                                     // 圣咏：块状和弦
            for m in cm { emit(m, 0, beat * 2.1, .random(in: 0.30 ... 0.42)) }
            let nd = prog[bar % prog.count]
            for d in [nd, nd + 2, nd + 4] {
                emit(fit(d, accidental(deg: d, chord: nd), near: 52, 48, 67).midi,
                     beat * 2, beat * 2.1, .random(in: 0.26 ... 0.38))
            }
        default:                                    // 八度低音
            for i in 0 ..< 4 {
                emit(root, Double(i) * beat, beat * 0.85, .random(in: 0.34 ... 0.46))
                if root + 12 <= 67 {
                    emit(root + 12, Double(i) * beat, beat * 0.85, .random(in: 0.24 ... 0.34))
                }
            }
        }

        // ── 右手旋律：按音级走 ──────────────────────────────
        let patterns: [[Int]] = [
            [2, 2, 2, 2], [4, 2, 2], [2, 2, 4], [1, 1, 2, 2, 2],
            [2, 1, 1, 2, 2], [8], [4, 4], [2, 2, 1, 1, 2], [3, 1, 2, 2],
        ]
        let pat = patterns.randomElement()!
        var t = 0.0
        for len8 in pat {
            let len = Double(len8) * beat / 2
            let strong = t.truncatingRemainder(dividingBy: beat) < 1e-6
            var acc = 0
            if strong, Double.random(in: 0 ... 1) < 0.62 {
                // 强拍落和弦音。最近的那个常常就是当前音本身 —— 老是选它，
                // 旋律就成了一串同音敲击，所以三分之二的时候跳过它取次近的。
                var cands: [Int] = []
                for c in triad {
                    let base = c + 7 * Int((Double(melDeg - c) / 7.0).rounded())
                    cands.append(contentsOf: [base - 7, base, base + 7])
                }
                cands.sort { abs($0 - melDeg) < abs($1 - melDeg) }
                var best = cands[0]
                if best == melDeg, Double.random(in: 0 ... 1) < 0.68,
                   let other = cands.first(where: { $0 != melDeg }) {
                    best = other
                }
                lastLeap = best - melDeg
                melDeg = best
            } else if abs(lastLeap) > 2 {
                // 古典声部进行：大跳之后反向级进填回来
                melDeg += lastLeap > 0 ? -1 : 1
                lastLeap = 0
            } else {
                let r = Double.random(in: 0 ... 1)
                let dir = Double.random(in: 0 ... 1) < 0.55 ? 1 : -1
                if r < 0.62 { melDeg += dir; lastLeap = dir }              // 级进
                else if r < 0.80 { melDeg += 2 * dir; lastLeap = 2 * dir } // 三度
                else if r < 0.90 { acc = dir; lastLeap = 0 }               // 半音邻音 → 黑键
                else { lastLeap = 0 }                                      // 同音
            }
            if acc == 0 { acc = accidental(deg: melDeg, chord: chord) }
            let f = fit(melDeg, acc, near: 76, 65, 89)
            melDeg = f.deg
            emit(f.midi, t, len * Double.random(in: 0.75 ... 0.95),
                 CGFloat.random(in: 0.55 ... 0.95) * (strong ? 1.12 : 0.9))
            t += len
        }
    }

    // ── 绘制 ────────────────────────────────────────────
    /// 键绕远端（顶边）向下倾倒。平面矩形绕水平轴转 θ 度、景深 d 时，
    /// 屏幕上就是一个梯形：底边上移到 L·cosθ·d/(d+L·sinθ)，同时按同一比例收窄。
    /// 所以不需要真的做 3D —— 直接画梯形，一次 Canvas 绘制搞定 42 个键。
    func draw(into context: inout GraphicsContext, size: CGSize) {
        guard size.width > 0 else { return }
        canvasSize = size
        let keyH = size.height - labelGutter
        guard keyH > 0 else { return }
        let ww = size.width / CGFloat(whiteCount)
        let sep = Color.primary.opacity(sepAlpha)

        func trapezoid(cx: CGFloat, halfW: CGFloat, len: CGFloat, p: CGFloat, black: Bool)
            -> (path: Path, bottom: CGFloat, halfBottom: CGFloat) {
            let theta = tiltDeg * .pi / 180 * p * (black ? blackTiltMul : 1)
            let d = black ? perspBlack : perspWhite
            let k = d / (d + len * sin(theta))
            let bottom = len * cos(theta) * k
            let hb = halfW * k
            var path = Path()
            path.move(to: CGPoint(x: cx - halfW, y: 0))
            path.addLine(to: CGPoint(x: cx + halfW, y: 0))
            path.addLine(to: CGPoint(x: cx + hb, y: bottom))
            path.addLine(to: CGPoint(x: cx - hb, y: bottom))
            path.closeSubpath()
            return (path, bottom, hb)
        }

        func footShadow(cx: CGFloat, halfW: CGFloat, bottom: CGFloat, p: CGFloat) {
            guard p > 0.02 else { return }
            let h = 4 + p * 13
            let r = CGRect(x: cx - halfW, y: bottom - h, width: halfW * 2, height: h)
            context.fill(Path(r), with: .linearGradient(
                Gradient(colors: [Color.primary.opacity(0), Color.primary.opacity(0.55 * shadowAlpha * p)]),
                startPoint: CGPoint(x: r.midX, y: r.minY),
                endPoint: CGPoint(x: r.midX, y: r.maxY)))
        }

        // 白键：宽度由缝隙定义，不填色；按下时给一层极淡的底
        for j in 0 ..< whiteCount {
            let p = press[j]
            let cx = (CGFloat(j) + 0.5) * ww
            let t = trapezoid(cx: cx, halfW: ww / 2, len: keyH, p: p, black: false)
            if p > 0.02 {
                context.fill(t.path, with: .color(Color.primary.opacity(0.085 * p)))
                footShadow(cx: cx, halfW: t.halfBottom, bottom: t.bottom, p: p)
            }
            if j < whiteCount - 1 {
                var line = Path()
                line.move(to: CGPoint(x: cx + ww / 2, y: 0))
                line.addLine(to: CGPoint(x: cx + t.halfBottom, y: t.bottom))
                context.stroke(line, with: .color(sep), lineWidth: 1)
            }
        }

        // 底边
        var base = Path()
        base.move(to: CGPoint(x: 0, y: keyH))
        base.addLine(to: CGPoint(x: size.width, y: keyH))
        context.stroke(base, with: .color(sep), lineWidth: 1)

        // 黑键：画面上唯一的实体
        let bw = ww * blackWRatio
        for (i, after) in blackAfter.enumerated() {
            let k = whiteCount + i
            let p = press[k]
            let cx = CGFloat(after) * ww
            let t = trapezoid(cx: cx, halfW: bw / 2, len: keyH * blackHRatio, p: p, black: true)
            context.fill(t.path, with: .color(Color.primary.opacity(blackAlpha * (1 + 0.28 * p))))
            footShadow(cx: cx, halfW: t.halfBottom, bottom: t.bottom, p: p)
        }
    }
}

/// 竖杠画布。刻意只吃 animator（无 @Published）和 paused 两个输入，配合 .equatable()
/// 挡住父视图每秒因倒计时触发的重算 —— 否则 TimelineView 会被连带重建，显示链调度
/// 要重新建立，表现出来就是每秒凝固一下。
private struct BarCanvas: View, Equatable {
    let animator: BarAnimator
    let paused: Bool

    static func == (a: BarCanvas, b: BarCanvas) -> Bool {
        a.animator === b.animator && a.paused == b.paused
    }

    var body: some View {
        TimelineView(.animation(paused: paused)) { timeline in
            Canvas { context, size in
                animator.width = size.width
                animator.advance(to: timeline.date)
                animator.draw(into: &context, size: size)
            }
        }
    }
}

/// 音符竖杠刻度时长选择器：点击竖杠开始/停止 + 波浪倒计时 + 唯一红线
struct FocusDurationPicker: View {
    @Binding var minutes: Int
    var isRunning: Bool
    var remainingSeconds: Double
    var onPick: (Int) -> Void

    @StateObject private var animator = BarAnimator()
    @State private var isHovering = false
    @State private var hoverMinute = 0
    @StateObject private var piano = PianoSynth()
    @State private var lastPlayedIdx = -1
    @State private var popoverOpen = false
    @State private var editingTime = false
    @State private var timeText = ""
    @FocusState private var timeFieldFocused: Bool

    /// 未开始时鼠标移到数字上就可以直接键入分钟数
    private var canEditTime: Bool { !isRunning && editingTime }

    /// 运行中把鼠标移到竖杠区域 —— 这时人想做的是结束，不是选时长
    private var showEndButton: Bool { isRunning && isHovering }

    private var keyboardHeight: CGFloat { BarAnimator.keyboardHeight }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(NSLocalizedString("FBPopoverView.focusLength.label", comment: "Focus length"))
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                Spacer()
                // ZStack 是稳定容器，两个子视图靠透明度互换。
                // 不能用 Group —— Group 会把修饰符分别套到每个子视图上，
                // Text / TextField 一切换 hover 追踪就断了。
                // 固定宽度也是必需的，否则「45」和「120:00」宽度不同会让布局跳。
                ZStack(alignment: .trailing) {
                    // 隐形基准：永远按最大的那个字号占位。
                    // hover 时字号 15→17，HStack 行高跟着变，NSPopover 又是自适应内容高度的，
                    // 表现出来就是整个面板上下抽一下。用一个不可见的最大字号 Text 把行高钉死，
                    // 字还是各自原生尺寸渲染（不是 scaleEffect 缩放），不会发虚。
                    Text("0")
                        .font(.title2.weight(.heavy))
                        .opacity(0)
                        .accessibilityHidden(true)
                    Text(topText)
                        .font(topFont)
                        .foregroundColor(topColor)
                        .opacity(canEditTime ? 0 : 1)
                        .animation(.easeOut(duration: 0.12), value: isHovering)
                    if canEditTime {
                        TextField("", text: $timeText)
                            .textFieldStyle(.plain)
                            .font(topFont)
                            .foregroundColor(focusRed)
                            .multilineTextAlignment(.trailing)
                            .focused($timeFieldFocused)
                            .onSubmit { commitTime(start: true) }
                            .onExitCommand { cancelTimeEdit() }
                    }
                }
                .frame(width: 82, alignment: .trailing)
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside {
                        beginTimeEdit()
                    } else if editingTime {
                        // 只在真的处于编辑态时才收值。之前这里判断的是 !timeFieldFocused，
                        // 但 beginTimeEdit 刚把焦点给了输入框，那个条件永远为假，
                        // 编辑态就卡住再也退不出来，顶部数字也不再跟着竖杠 hover 走了。
                        // 反过来也不能无条件 commit —— 运行中鼠标路过时 timeText 是上一次
                        // 编辑的陈旧值，会把 minutes 改掉。
                        commitTime(start: false)
                    }
                }
                .onChange(of: timeFieldFocused) { focused in
                    // 点到别处失焦：把已经输入的值收下来，但不自动开始
                    if !focused && editingTime { commitTime(start: false) }
                }
                .onChange(of: isRunning) { running in
                    if running { cancelTimeEdit() }
                }
                Text(NSLocalizedString("FBPopoverView.min", comment: "min"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ZStack {
                BarCanvas(animator: animator, paused: !popoverOpen)
                    .equatable()
                    .opacity(showEndButton ? 0 : 1)
                    .scaleEffect(showEndButton ? 0.985 : 1)
                    .allowsHitTesting(!showEndButton)

                if isRunning {
                    Button {
                        onPick(0)       // 运行中 onPick 的参数被忽略，语义就是「结束」
                    } label: {
                        Text(NSLocalizedString("FBPopoverView.endFocus.label", comment: "End focus"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(focusRed)
                            )
                    }
                    .buttonStyle(.plain)
                    .opacity(showEndButton ? 1 : 0)
                    .scaleEffect(showEndButton ? 1 : 0.96)
                    .allowsHitTesting(showEndButton)
                }
            }
            .frame(height: keyboardHeight)
            .animation(.easeOut(duration: 0.18), value: showEndButton)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    isHovering = true
                    if isRunning {
                        // 运行中鼠标移进来是为了暂停，不是选时长：不按键、不响音。
                        // 双手演奏在按钮底下继续，淡回来时是接着弹的，不会卡一下。
                        animator.hoverKey = nil
                        lastPlayedIdx = -1
                    } else {
                        let k = animator.key(at: location)
                        animator.hoverKey = k
                        hoverMinute = animator.minutes(white: animator.whiteIndex(of: k))
                        // 每个键响自己那一份录音，黑白键一视同仁
                        if k != lastPlayedIdx {
                            lastPlayedIdx = k
                            piano.play(semitone: animator.semitone(of: k), volume: keyVolume)
                        }
                    }
                case .ended:
                    isHovering = false
                    animator.hoverKey = nil
                    lastPlayedIdx = -1
                }
            }
            .gesture(
                SpatialTapGesture().onEnded { value in
                    guard !isRunning else { return }   // 运行中由「暂停专注」按钮接管
                    onPick(animator.minutes(at: value.location))
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
            // 否则 TimelineView 会在 popover 关着的时候继续按刷新率空转。
            //
            // 用 willShow 而不是 didShow：didShow 要等 popover 的展开动画放完才发，
            // 实测比 willShow 晚 520ms —— 那段时间画面停在关闭前的最后一帧上不动，
            // 看起来就是「打开后先静止半秒，然后突然跳起来」。
            .onReceive(NotificationCenter.default.publisher(for: NSPopover.willShowNotification)) { _ in
                animator.warmUp(to: Date())
                popoverOpen = true
            }
            // 兜底：万一 willShow 没收到（幂等，warmUp 只在还没放行时才有意义）
            .onReceive(NotificationCenter.default.publisher(for: NSPopover.didShowNotification)) { _ in
                if !popoverOpen {
                    animator.warmUp(to: Date())
                    popoverOpen = true
                }
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

    private func beginTimeEdit() {
        guard !isRunning, !editingTime else { return }
        timeText = "\(minutes)"
        editingTime = true
        timeFieldFocused = true
    }

    /// start 为真表示按了回车 —— 直接用输入值开始，否则只是把值收下来
    private func commitTime(start: Bool) {
        let trimmed = timeText.trimmingCharacters(in: .whitespaces)
        let picked = Int(trimmed).map { min(125, max(1, $0)) }   // 25 个白键 = 5~125 分
        if let picked { minutes = picked }
        editingTime = false
        timeFieldFocused = false
        if start, let picked { onPick(picked) }
    }

    private func cancelTimeEdit() {
        editingTime = false
        timeFieldFocused = false
    }

    private var topText: String {
        if isRunning {          // 运行中恒显示倒计时，hover 不再改写它
            let s = max(0, Int(ceil(remainingSeconds)))
            return String(format: "%d:%02d", s / 60, s % 60)
        }
        return "\(isHovering ? hoverMinute : minutes)"
    }

    /// 读数恒为番茄红 —— 未开始、hover 预览、运行中都一样，不再在黑色和强调色之间跳
    private var topColor: Color { focusRed }

    private var topFont: Font {
        (isHovering || isRunning) ? .title2.weight(.heavy) : .title3.bold()
    }

}
