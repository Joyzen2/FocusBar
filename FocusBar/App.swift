import SwiftUI

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
    private var popover = NSPopover()
    private var statusBarItem: NSStatusItem?
    static var shared: FBStatusItem!

    func applicationDidFinishLaunching(_: Notification) {
        let view = FBPopoverView()

        popover.behavior = .transient
        popover.contentViewController = NSViewController()
        popover.contentViewController?.view = NSHostingView(rootView: view)
        if let contentViewController = popover.contentViewController {
            popover.contentSize.height = contentViewController.view.intrinsicContentSize.height
            popover.contentSize.width = 280
        }

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

    func showPopover(_: AnyObject?) {
        if let button = statusBarItem?.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: NSRectEdge.minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func closePopover(_ sender: AnyObject?) {
        popover.performClose(sender)
    }

    @objc func togglePopover(_ sender: AnyObject?) {
        if popover.isShown {
            closePopover(sender)
        } else {
            showPopover(sender)
        }
    }
}
