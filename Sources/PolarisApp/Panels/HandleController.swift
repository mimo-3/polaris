import AppKit
import SwiftUI

/// 閉じた付箋がクリックを通しているあいだ、付箋の画面中央側の縁の内側に重ねる「つまみ」。
/// クリックを通すかは窓ごとにしか決められないので、つまみは小さな別の窓にして付箋の上に置く。ここだけはクリックを受け取る。ホバーでは開かず、クリックで開閉、ドラッグで付箋ごと動かす。
@MainActor
final class HandleController {
    private let panel: FloatingPanel
    private let host: HandleHostingView
    /// 吹き出しはクリックを通す別の窓に出す。つまみの窓を広げると、その分だけ後ろを塞ぐため。
    private let hintPanel: FloatingPanel
    private let hintHost: NSHostingView<HandleHintView>
    private let model: NoteModel

    var onClick: () -> Void = {}
    var onDrag: (DragPhase) -> Void = { _ in }

    var frame: NSRect { panel.isVisible ? panel.frame : .zero }

    init(model: NoteModel) {
        self.model = model
        let size = NSSize(width: PolarisTheme.Metrics.handleWidth, height: PolarisTheme.Metrics.handleHeight)
        panel = FloatingPanel(size: size, keyable: false)
        panel.hasShadow = false
        // 付箋の窓より常に上に置く。付箋が key になって前へ出ても隠れないようにする。
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.setAccessibilityLabel(Copy.handleLabel)
        host = HandleHostingView(rootView: HandleGrip(hovered: false, theme: model.theme))
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host

        hintPanel = FloatingPanel(size: NSSize(width: 10, height: 10), keyable: false)
        hintPanel.hasShadow = false
        hintPanel.ignoresMouseEvents = true
        hintPanel.level = panel.level
        hintHost = NSHostingView(rootView: HandleHintView(text: "", theme: model.theme))
        hintHost.sizingOptions = []
        hintPanel.contentView = hintHost

        host.onHover = { [weak self] in self?.hoverChanged($0) }
        host.onClick = { [weak self] in self?.hoverChanged(false); self?.onClick() }
        host.onDrag = { [weak self] phase in
            self?.hoverChanged(false)
            self?.onDrag(phase)
        }
        // VoiceOver からも開閉できるようにする。
        host.setAccessibilityElement(true)
        host.setAccessibilityRole(.button)
        host.setAccessibilityLabel(Copy.handleLabel)
    }

    /// 付箋の枠に合わせて、画面中央側の縁の内側・閉じたときの高さの真ん中に置く。
    /// - Parameters:
    ///   - note: 付箋の窓の枠。
    ///   - collapsedHeight: 閉じたときの付箋の高さ。開いていても、つまみの位置を動かさないため。
    func place(beside note: NSRect, corner: Corner, collapsedHeight: CGFloat) {
        let m = PolarisTheme.Metrics.self
        let x = corner.isLeft ? note.maxX - m.handleInset - m.handleWidth : note.minX + m.handleInset
        let midY = corner.isTop ? note.maxY - collapsedHeight / 2 : note.minY + collapsedHeight / 2
        panel.setFrame(NSRect(x: x, y: midY - m.handleHeight / 2, width: m.handleWidth, height: m.handleHeight), display: true)
        if hintPanel.isVisible { placeHint() }
    }

    func setVisible(_ visible: Bool) {
        if visible {
            guard !panel.isVisible else { return }
            host.rootView = HandleGrip(hovered: false, theme: model.theme)
            panel.orderFrontRegardless()
        } else {
            hoverChanged(false)
            panel.orderOut(nil)
        }
    }

    func setAlpha(_ alpha: CGFloat) { panel.alphaValue = alpha }

    private func hoverChanged(_ hovered: Bool) {
        if hovered { model.pointerOnHandle() }
        host.rootView = HandleGrip(hovered: hovered, expanded: model.expanded, theme: model.theme)
        if hovered {
            NSCursor.openHand.set()
            hintHost.rootView = HandleHintView(text: model.expanded ? Copy.handleHelpOpen : Copy.handleHelpClosed, theme: model.theme)
            placeHint()
            hintPanel.orderFrontRegardless()
        } else {
            hintPanel.orderOut(nil)
        }
    }

    /// 吹き出しは付箋の外、つまみのさらに画面中央側に、縦の真ん中を揃えて出す。
    private func placeHint() {
        let size = hintHost.fittingSize
        let handle = panel.frame
        let gap = PolarisTheme.Metrics.handleInset + 6
        let x = model.corner.isLeft ? handle.maxX + gap : handle.minX - gap - size.width
        hintPanel.setFrame(NSRect(x: x, y: handle.midY - size.height / 2, width: size.width, height: size.height), display: true)
    }
}

/// つまみの見た目。付箋の縁に沿った帯に、掴めそうな点を2列×3段。
/// ホバーすると点を開閉の矢印に替え、押せば開く（閉じる）ことを見せる。
struct HandleGrip: View {
    var hovered: Bool
    var expanded: Bool = false
    var theme: ThemeContext

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PolarisTheme.Metrics.handleWidth / 2, style: .continuous)
        ZStack {
            shape.fill(hovered ? PolarisTheme.Palette.pressFill : PolarisTheme.Palette.hoverFill)
            if theme.increaseContrast { shape.strokeBorder(PolarisTheme.Palette.HighContrast.border, lineWidth: 1) }
            if hovered {
                Image(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.ink)
                    .transition(.opacity)
            } else {
                Grid(horizontalSpacing: 2.5, verticalSpacing: 3.5) {
                    ForEach(0..<3, id: \.self) { _ in
                        GridRow {
                            Circle().frame(width: 3, height: 3)
                            Circle().frame(width: 3, height: 3)
                        }
                    }
                }
                .foregroundStyle(theme.ink2)
                .transition(.opacity)
            }
        }
        .frame(width: PolarisTheme.Metrics.handleWidth, height: PolarisTheme.Metrics.handleHeight)
        .animation(.easeOut(duration: theme.reduceMotion ? 0 : 0.12), value: hovered)
        .environment(\.polaris, theme)
    }
}

private struct HandleHintView: View {
    var text: String
    var theme: ThemeContext

    var body: some View {
        HintBubble(text: text).environment(\.polaris, theme)
    }
}

/// つまみの窓の中身。ジェスチャは SwiftUI ではなく AppKit のマウスイベントで受ける。
/// 非アクティブなアプリの nonactivating パネルでも、最初のクリックから確実に届くようにするため。
final class HandleHostingView: NSHostingView<HandleGrip> {
    var onHover: (Bool) -> Void = { _ in }
    var onClick: () -> Void = {}
    var onDrag: (DragPhase) -> Void = { _ in }
    private var area: NSTrackingArea?
    private var downAt: NSPoint?
    private var dragging = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        self.area = area
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { if downAt == nil { onHover(false) } }
    override func cursorUpdate(with event: NSEvent) { NSCursor.openHand.set() }

    override func mouseDown(with event: NSEvent) {
        downAt = NSEvent.mouseLocation
        dragging = false
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downAt else { return }
        let now = NSEvent.mouseLocation
        if !dragging, hypot(now.x - start.x, now.y - start.y) < 3 { return }
        dragging = true
        onDrag(.changed)
    }

    override func mouseUp(with event: NSEvent) {
        defer { downAt = nil; dragging = false }
        NSCursor.openHand.set()
        if dragging { onDrag(.ended) } else { onClick() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick()
        return true
    }
}
