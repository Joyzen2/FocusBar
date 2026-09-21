import SwiftUI

extension Notification.Name {
    /// 自绘面板的开关通知。原来用的是 NSPopover.willShow/didClose，
    /// 换成 NSPanel 之后那些系统通知不再发，得自己发。
    static let fbPanelWillShow = Notification.Name("FBPanelWillShow")
    static let fbPanelDidClose = Notification.Name("FBPanelDidClose")
}

/// 无边框窗口默认不能成为 key window，不覆盖的话输入框收不到键盘、⌘Q 也不响应。
final class FBPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

extension NSImage.Name {
    static let idle = Self("BarIconIdle")
    static let running = Self("BarIconWork")
}

private let digitFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

@main
struct FBApp: App {
    @NSApplicationDelegateAdaptor(FBStatusItem.self) var appDelegate

    init() {
        FBStatusItem.shared = appDelegate
    }

    var body: some Scene {
        Settings {}
    }
}

class FBStatusItem: NSObject, NSApplicationDelegate {
    // 系统菜单栏的那些菜单（Wi-Fi、音量、电池）从 Big Sur 起就是无箭头的圆角矩形。
    // NSPopover 永远会画指向状态项的小三角 —— 那是它自己 frame view 画的，
    // 没有公开 API 能关掉，只能去动私有视图层级，跨系统版本太脆。
    // 所以这里自己搭一个 NSPanel：系统菜单材质 + 圆角 + 无箭头。
    private var panel: FBPanel?
    private var statusBarItem: NSStatusItem?
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    static var shared: FBStatusItem!

    /// 面板圆角。从系统 Wi-Fi 菜单的截图上量的：那个角不是圆弧 —— 圆弧拟合残差 0.82，
    /// 超椭圆 n=4（Apple 的连续曲率）降到 0.22，可见半径约 18pt。
    /// NSGlassEffectView 自己会画连续曲率，这里只要给半径。
    private let cornerRadius: CGFloat = 18
    /// 面板顶边距菜单栏底边的距离，系统菜单大约就是这么多
    private let menuBarGap: CGFloat = 5
    private let panelWidth: CGFloat = 280

    func applicationDidFinishLaunching(_: Notification) {
        buildPanel()

        statusBarItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        statusBarItem?.button?.imagePosition = .imageLeft
        setIcon(name: .idle)
        statusBarItem?.button?.action = #selector(FBStatusItem.togglePopover(_:))
    }

    func setTitle(title: String?) {
        guard let title = title, !title.isEmpty else {
            statusBarItem?.button?.attributedTitle = NSAttributedString(string: "")
            return
        }
        let badgeImage = makeBadgeImage(text: " \(title) ")
        let attachment = NSTextAttachment()
        attachment.image = badgeImage
        attachment.bounds = NSRect(x: 0, y: -7, width: badgeImage.size.width, height: badgeImage.size.height)
        statusBarItem?.button?.attributedTitle = NSAttributedString(attachment: attachment)
    }

    /// 生成带椭圆边框的时间胶囊图片（参数来自设计工坊）
    private func makeBadgeImage(text: String) -> NSImage {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: digitFont,
            .foregroundColor: NSColor.labelColor
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)

        let padH: CGFloat = 8
        let padV: CGFloat = 2
        let borderW: CGFloat = 1.5
        let radius: CGFloat = 7

        let size = NSSize(width: ceil(textSize.width) + padH * 2 + borderW * 2,
                          height: ceil(textSize.height) + padV * 2 + borderW * 2)

        return NSImage(size: size, flipped: true) { _ in
            let borderRect = NSRect(x: 0, y: 0, width: size.width, height: size.height)
                .insetBy(dx: borderW / 2, dy: borderW / 2)
            let path = NSBezierPath(roundedRect: borderRect, xRadius: radius, yRadius: radius)
            path.lineWidth = borderW
            NSColor.labelColor.setStroke()
            path.stroke()

            let textRect = NSRect(x: borderW + padH, y: borderW + padV,
                                  width: textSize.width, height: textSize.height)
            (text as NSString).draw(in: textRect, withAttributes: attrs)
            return true
        }
    }

    func setIcon(name: NSImage.Name) {
        if let image = NSImage(named: name) {
            image.size = NSSize(width: 20, height: 20)
            image.alignmentRect = NSRect(x: 0, y: 2, width: 20, height: 20)
            statusBarItem?.button?.image = image
        }
    }

    // ── 面板 ────────────────────────────────────────────

    private func buildPanel() {
        let hosting = NSHostingView(rootView: FBPopoverView())
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let height = hosting.fittingSize.height
        let frame = NSRect(x: 0, y: 0, width: panelWidth, height: height)
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.frame = frame
        hosting.autoresizingMask = [.width, .height]

        // macOS 26 起系统菜单用的是 Liquid Glass，不再是老的 .menu 材质。
        // NSGlassEffectView 自己画连续曲率圆角、镜面顶边和那圈极淡的亮边 ——
        // 上一版我拿 NSVisualEffectView + layer.borderWidth 手画描边，方向就错了：
        // 系统那条亮边是材质的高光（实测顶边亮度 94，面板内部才 46），不是描边。
        let container: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: frame)
            glass.style = .regular
            glass.cornerRadius = cornerRadius
            glass.contentView = hosting
            container = glass
        } else {
            let effect = NSVisualEffectView(frame: frame)
            effect.material = .menu
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = cornerRadius
            effect.layer?.cornerCurve = .continuous
            effect.layer?.masksToBounds = true
            effect.addSubview(hosting)
            container = effect
        }
        container.autoresizingMask = [.width, .height]

        // 玻璃视图必须当**子视图**用，不能直接当窗口的 contentView ——
        // 它要采样自己背后的内容，当 contentView 时窗口那层矩形背景就压在它下面，
        // 圆角外的缺口会透出黑色，看起来像被一个黑框套住。
        // 所以窗口的 contentView 是一张完全透明的底板，玻璃铺在上面。
        let base = NSView(frame: frame)
        base.wantsLayer = true
        base.layer?.backgroundColor = NSColor.clear.cgColor
        // 底板自己也裁成圆角：这样整个窗口内容的 alpha 通道就是圆角形状，
        // 视图层级里再没有任何东西能画出矩形边。
        base.layer?.cornerRadius = cornerRadius
        base.layer?.cornerCurve = .continuous
        base.layer?.masksToBounds = true
        base.autoresizingMask = [.width, .height]
        base.addSubview(container)

        let p = FBPanel(contentRect: frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        // 先关不透明再挂内容：顺序反了的话窗口会先按不透明算一遍阴影
        p.isOpaque = false
        p.backgroundColor = .clear
        p.contentView = base
        // 窗口阴影是按 alpha 通道算的，玻璃视图的 backdrop 似乎让它算成了整块矩形，
        // 在暗背景上就是一圈黑边。先关掉窗口阴影，确认黑框消失后再用图层阴影补回来 ——
        // 图层阴影跟着圆角路径走，不会有这个问题。
        p.hasShadow = false
        p.level = .popUpMenu
        p.isMovable = false
        p.hidesOnDeactivate = false
        p.animationBehavior = .utilityWindow
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel = p
    }

    /// 摆在状态项正下方，并夹在屏幕可见区域内
    private func position(_ p: NSPanel) {
        guard let button = statusBarItem?.button, let win = button.window else { return }
        let onScreen = win.convertToScreen(button.convert(button.bounds, to: nil))
        var frame = p.frame
        frame.size.width = panelWidth
        frame.origin.x = onScreen.midX - frame.width / 2
        frame.origin.y = onScreen.minY - frame.height - menuBarGap
        if let vf = (win.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = min(max(frame.origin.x, vf.minX + 8), vf.maxX - frame.width - 8)
        }
        p.setFrame(frame, display: false)
    }

    func showPopover(_: AnyObject?) {
        guard let p = panel else { return }
        // 先发通知再显示：动画需要在第一帧之前就被放行，否则画面会停在关闭前那一帧。
        // 这正是原来用 willShow 而不是 didShow 的原因，换成面板后这个次序要自己保证。
        NotificationCenter.default.post(name: .fbPanelWillShow, object: nil)
        position(p)
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installMonitors()
    }

    func closePopover(_: AnyObject?) {
        guard let p = panel, p.isVisible else { return }
        removeMonitors()
        p.orderOut(nil)
        NotificationCenter.default.post(name: .fbPanelDidClose, object: nil)
    }

    @objc func togglePopover(_ sender: AnyObject?) {
        if panel?.isVisible == true {
            closePopover(sender)
        } else {
            showPopover(sender)
        }
    }

    /// NSPopover 的 .transient 行为要自己补：点别处关掉、Esc 关掉。
    /// 全局监视器收不到本应用自己的事件，所以点状态项不会走这里 —— 那一路由
    /// togglePopover 的 isVisible 判断接管，不会出现「关掉又立刻打开」。
    private func installMonitors() {
        removeMonitors()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.closePopover(nil)
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {           // Esc
                self?.closePopover(nil)
                return nil
            }
            return event
        }
    }

    private func removeMonitors() {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }
}
