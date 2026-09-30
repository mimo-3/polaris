import AppKit
import SwiftUI

/// 全 Space・フルスクリーンの上にも出る、フォーカスを奪わないパネル。
final class FloatingPanel: NSPanel {
    private let keyable: Bool

    init(size: NSSize, keyable: Bool) {
        self.keyable = keyable
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isFloatingPanel = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        isMovable = false
        // 枠なしのパネルは AX の subrole が unknown になり、VoiceOver のウインドウ一覧や自動操作から辿りにくい。
        // フォーカスを奪わない浮いた窓であることを明示しておく（nonactivating でも AXPress は届く）。
        setAccessibilitySubrole(.floatingWindow)
        setAccessibilityLabel("Polaris")
    }

    override var canBecomeKey: Bool { keyable }
    override var canBecomeMain: Bool { false }
}

/// 非アクティブなアプリでもポインタを拾うために、activeAlways の tracking area を自前で張る。
final class TrackingHostingView<Content: View>: NSHostingView<Content> {
    var onEnter: () -> Void = {}
    var onExit: () -> Void = {}
    /// SwiftUI と同じ左上原点の座標で渡す。
    var onMove: (CGPoint) -> Void = { _ in }
    private var area: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        self.area = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onEnter()
        report(event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        report(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onExit()
    }

    private func report(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        onMove(CGPoint(x: p.x, y: isFlipped ? p.y : bounds.height - p.y))
    }
}

extension NSScreen {
    var displayUUID: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// 隅に `size` を置いたときの frame。visibleFrame から screenInset だけ内側。
    func frame(for size: NSSize, at corner: Corner) -> NSRect {
        let inset = PolarisTheme.Metrics.screenInset
        let vf = visibleFrame
        let x = corner.isLeft ? vf.minX + inset : vf.maxX - inset - size.width
        let y = corner.isTop ? vf.maxY - inset - size.height : vf.minY + inset
        return NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    /// 点が属する象限の隅。
    func corner(nearest point: NSPoint) -> Corner {
        let vf = visibleFrame
        let left = point.x < vf.midX, top = point.y > vf.midY
        switch (top, left) {
        case (true, true): return .topLeft
        case (true, false): return .topRight
        case (false, true): return .bottomLeft
        case (false, false): return .bottomRight
        }
    }
}

extension Corner {
    /// sheetIn の拡大の起点。
    var unitPoint: UnitPoint {
        switch self {
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomRight: .bottomTrailing
        case .bottomLeft: .bottomLeading
        }
    }
}
