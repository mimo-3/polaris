import AppKit
import SwiftUI

/// 朝の支度シート・クイック編集・寄り道の簡易パネル。付箋と同じ隅を起点に、画面中心側へ出す。
@MainActor
final class AuxPanelController {
    let panel: FloatingPanel
    private let hosting: NSHostingView<AnyView>
    private let width: CGFloat
    private let place: () -> (NSScreen?, Corner)
    private var previousApp: NSRunningApplication?
    private var closeTask: _Concurrency.Task<Void, Never>?
    private var observer: NSObjectProtocol?
    var onClose: () -> Void = {}

    init(width: CGFloat, keyable: Bool, clickThrough: Bool = false, place: @escaping () -> (NSScreen?, Corner)) {
        self.width = width
        self.place = place
        panel = FloatingPanel(size: NSSize(width: width, height: 200), keyable: keyable)
        panel.ignoresMouseEvents = clickThrough
        panel.becomesKeyOnlyIfNeeded = false
        hosting = NSHostingView(rootView: AnyView(EmptyView()))
        hosting.sizingOptions = []
        panel.contentView = hosting
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.previousApp = nil }
        }
    }

    /// 通知の購読をやめる。作り直すときに呼ぶ。
    func teardown() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    var isVisible: Bool { panel.isVisible }

    /// `key` が false のときは前面アプリの入力を奪わない。クリックされたら key になる。
    func present<Content: View>(_ content: Content, theme: ThemeContext, key: Bool, autoClose: TimeInterval? = nil) {
        closeTask?.cancel()
        let (_, corner) = place()
        hosting.rootView = AnyView(
            AuxRoot(corner: corner, reduceMotion: theme.reduceMotion,
                    onHeight: { [weak self] in self?.resize(to: $0) }) { content }
                .environment(\.polaris, theme)
                .id(UUID())
        )
        resize(to: max(hosting.fittingSize.height, 100))
        panel.alphaValue = 1
        if key {
            if let front = NSWorkspace.shared.frontmostApplication, front != .current { previousApp = front }
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
        if let autoClose {
            closeTask = _Concurrency.Task { @MainActor [weak self] in
                try? await _Concurrency.Task.sleep(for: .seconds(autoClose))
                guard !_Concurrency.Task.isCancelled else { return }
                self?.close()
            }
        }
    }

    func makeKey() {
        if let front = NSWorkspace.shared.frontmostApplication, front != .current { previousApp = front }
        panel.makeKeyAndOrderFront(nil)
    }

    /// 閉じたら直前のアプリへフォーカスを返す。
    func close() {
        closeTask?.cancel()
        guard panel.isVisible else { return }
        let wasKey = panel.isKeyWindow
        let app = previousApp
        previousApp = nil
        panel.orderOut(nil)
        hosting.rootView = AnyView(EmptyView())
        if wasKey, let app, !app.isTerminated { app.activate() }
        onClose()
    }

    private func resize(to height: CGFloat) {
        let (screen, corner) = place()
        guard let screen = screen ?? NSScreen.main else { return }
        panel.setFrame(screen.frame(for: NSSize(width: width, height: ceil(height)), at: corner), display: true)
        panel.invalidateShadow()
    }
}

/// 隅を起点に scale 0.96→1 ＋ opacity で出す。
private struct AuxRoot<Content: View>: View {
    var corner: Corner
    var reduceMotion: Bool
    var onHeight: (CGFloat) -> Void
    @ViewBuilder var content: Content
    @State private var shown = false

    var body: some View {
        VStack(spacing: 0) {
            if !corner.isTop { Spacer(minLength: 0) }
            content
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { onHeight($0) }
            if corner.isTop { Spacer(minLength: 0) }
        }
        .scaleEffect(shown || reduceMotion ? 1 : 0.96, anchor: corner.unitPoint)
        .opacity(shown ? 1 : 0)
        .onAppear { withAnimation(PolarisTheme.Motion.sheetIn(reduceMotion)) { shown = true } }
    }
}
