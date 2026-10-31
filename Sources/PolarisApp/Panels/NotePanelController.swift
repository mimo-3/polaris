import AppKit
import SwiftUI

/// 付箋パネルの位置・高さ・表示・クリック透過・key の出し入れを受け持つ。
@MainActor
final class NotePanelController {
    let model: NoteModel
    let panel: FloatingPanel
    /// 透過中だけ内側の縁に重ねるつまみ。
    let handle: HandleController
    private let hosting: TrackingHostingView<NotePanelRoot>
    private var panelHeight: CGFloat = 150
    private var contentHeight: CGFloat = 150
    /// 閉じているときの高さ。開いていても、つまみをこの高さの真ん中に置いて動かさない。
    private var collapsedHeight: CGFloat = 150
    private var shrinkTask: _Concurrency.Task<Void, Never>?
    private var peekTimer: Timer?
    private var hideTimer: _Concurrency.Task<Void, Never>?
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    private var previousApp: NSRunningApplication?
    private var displayUUID: String?
    private var observers: [NSObjectProtocol] = []
    /// mouseExited は窓の伸び縮みやメニューの後に来ないことがある。カーソルの位置を直接見て、取りこぼしを拾う。
    private var leaveWatch: Timer?
    private var outsideSince: Date?

    /// ⌃⌥H などで隠している。
    private(set) var isHidden = false
    /// 「15分だけ隠す」の最中。寄り道も出さない。
    private(set) var hiddenUntil: Date?
    /// メニューバーのアイコンを切り替えるため。
    var onVisibilityChanged: (Bool) -> Void = { _ in }

    init(model: NoteModel) {
        self.model = model
        panel = FloatingPanel(size: NSSize(width: PolarisTheme.Metrics.noteWidth, height: 150), keyable: true)
        panel.becomesKeyOnlyIfNeeded = true
        handle = HandleController(model: model)
        hosting = TrackingHostingView(rootView: NotePanelRoot(model: model, onHeight: { _ in }, onDrag: { _ in }))
        hosting.sizingOptions = []
        panel.contentView = hosting
        hosting.rootView = NotePanelRoot(model: model,
                                         onHeight: { [weak self] in self?.contentHeightChanged($0) },
                                         onDrag: { [weak self] in self?.drag($0) })
        hosting.onEnter = { [weak model] in model?.pointerEntered() }
        hosting.onExit = { [weak model] in model?.pointerExited() }
        hosting.onMove = { [weak model] in model?.pointer = $0 }
        // 声の行が banner などでモード表示の行が無いときも開閉できるよう、窓にも同じ操作を付ける。
        panel.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: Copy.expandAction) { [weak model] in
                MainActor.assumeIsolated { model?.setExpanded(true) }
                return true
            },
            NSAccessibilityCustomAction(name: Copy.collapseAction) { [weak model] in
                MainActor.assumeIsolated { model?.setExpanded(false) }
                return true
            },
        ])
        model.requestKey = { [weak self] in self?.makeKey() }
        model.resignKey = { [weak self] in self?.releaseKey() }
        model.interactivityChanged = { [weak self] in self?.applyInteractivity() }
        handle.onClick = { [weak model] in model?.toggleFromHandle() }
        handle.onDrag = { [weak self] in self?.drag($0) }
        restorePlacement()

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.isKey = true }
        })
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.isKey = false
                self.model.keyboardIndex = nil
                self.model.finishEditingOnResign()
            }
        })
        // .default の run loop mode だけで回すので、メニューを開いている間（eventTracking）は止まる。
        leaveWatch = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchLeave() }
        }
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.placeAtCorner(animated: false) }
        })
        // つまみは付箋の脇に付いて回る。
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            observers.append(center.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.layoutHandle() }
            })
        }
        setClickThrough(model.clickThrough)
    }

    /// 通知の購読をやめる。作り直すときに呼ぶ。
    func teardown() {
        leaveWatch?.invalidate()
        leaveWatch = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    private func watchLeave() {
        guard panel.isVisible, model.expanded, !panel.frame.contains(NSEvent.mouseLocation) else {
            outsideSince = nil
            return
        }
        let since = outsideSince ?? Date()
        outsideSince = since
        if Date().timeIntervalSince(since) >= PolarisTheme.Motion.leaveDelay {
            outsideSince = nil
            model.collapseIfLeft()
        }
    }

    // MARK: 表示

    func show() {
        hideTimer?.cancel()
        hiddenUntil = nil
        isHidden = false
        model.hidden = false
        onVisibilityChanged(false)
        placeAtCorner(animated: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        updateHandle()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = PolarisTheme.Motion.visibilityDuration
            panel.animator().alphaValue = 1
        }
    }

    /// `minutes` を渡すとその時間だけ隠し、時間が来たら戻す。
    func hide(for minutes: Double? = nil) {
        isHidden = true
        model.hidden = true
        onVisibilityChanged(true)
        model.unpinAll()
        handle.setVisible(false)
        hideTimer?.cancel()
        if let minutes {
            hiddenUntil = Date().addingTimeInterval(minutes * 60)
            hideTimer = _Concurrency.Task { @MainActor [weak self] in
                try? await _Concurrency.Task.sleep(for: .seconds(minutes * 60))
                guard !_Concurrency.Task.isCancelled else { return }
                self?.show()
            }
        } else {
            hiddenUntil = nil
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = PolarisTheme.Motion.visibilityDuration
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { if self?.isHidden == true { self?.panel.orderOut(nil) } }
        })
    }

    func toggleVisibility() { isHidden ? show() : hide() }

    // MARK: クリック透過

    /// 閉じた付箋がクリックを後ろへ通すか。通すあいだは、脇のつまみだけが触れる場所になる。
    func setClickThrough(_ on: Bool) {
        model.clickThrough = on
        model.optionPeek = false
        if on { model.unpinAll() }
        applyInteractivity()
        peekTimer?.invalidate()
        guard on else { return }
        // ⌥ を押していて、ポインタが付箋の上にあるあいだだけ触れる。グローバル監視は使わない。
        peekTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollPeek() }
        }
    }

    private func pollPeek() {
        let peek = NSEvent.modifierFlags.contains(.option) && panel.frame.contains(NSEvent.mouseLocation)
        guard peek != model.optionPeek else { return }
        model.optionPeek = peek
        if !peek && !model.handleOpen { model.unpinAll() }
    }

    /// クリックを受け取れるかを窓に反映し、つまみを出し入れする。
    private func applyInteractivity() {
        panel.ignoresMouseEvents = !model.interactive
        updateHandle()
    }

    private func updateHandle() {
        let visible = model.clickThrough && !isHidden && panel.isVisible
        if visible { layoutHandle() }
        handle.setVisible(visible)
    }

    private func layoutHandle() {
        handle.place(beside: panel.frame, corner: model.corner, collapsedHeight: min(collapsedHeight, panel.frame.height))
    }

    // MARK: key

    /// テキスト入力と ⌃⌥O のときだけ key にする。アプリ自体はアクティブにしない。
    func makeKey() {
        if let front = NSWorkspace.shared.frontmostApplication, front != .current { previousApp = front }
        if isHidden { show() }
        panel.makeKeyAndOrderFront(nil)
    }

    /// ⌃⌥O: 展開を固定して key にする。
    func focusForKeyboard() {
        if !model.pinned { model.togglePin() }
        model.keyboardIndex = model.initialKeyboardIndex
        makeKey()
    }

    /// key を外して直前のアプリへ返す。NSApp.hide は使わない。
    func releaseKey() {
        guard panel.isKeyWindow else { return }
        let app = previousApp
        previousApp = nil
        if let app, !app.isTerminated { app.activate() } else { panel.resignKey() }
    }

    // MARK: 高さ（画面の中心側へ伸ばす）

    private func contentHeightChanged(_ height: CGFloat) {
        let target = ceil(height)
        if !model.expanded { collapsedHeight = target }
        guard target != contentHeight else { return }
        contentHeight = target
        shrinkTask?.cancel()
        if target > panelHeight {
            // 伸ばすときは先に frame を広げ、中身は SwiftUI の spring で伸ばす。
            setPanelHeight(target)
        } else {
            // 縮めるときは spring が終わってから frame を縮める。
            shrinkTask = _Concurrency.Task { @MainActor [weak self] in
                try? await _Concurrency.Task.sleep(for: .seconds(PolarisTheme.Motion.shrinkSettle))
                guard let self, !_Concurrency.Task.isCancelled else { return }
                self.setPanelHeight(self.contentHeight)
            }
        }
    }

    private func setPanelHeight(_ height: CGFloat) {
        panelHeight = height
        guard let screen = currentScreen else { return }
        panel.setFrame(screen.frame(for: NSSize(width: PolarisTheme.Metrics.noteWidth, height: height), at: model.corner),
                       display: true)
        panel.invalidateShadow()
    }

    // MARK: 位置

    private var currentScreen: NSScreen? {
        NSScreen.screens.first { $0.displayUUID == displayUUID } ?? NSScreen.main ?? NSScreen.screens.first
    }

    func placeAtCorner(animated: Bool) {
        guard let screen = currentScreen else { return }
        let target = screen.frame(for: NSSize(width: PolarisTheme.Metrics.noteWidth, height: panelHeight), at: model.corner)
        if animated && !model.theme.reduceMotion {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = PolarisTheme.Motion.snapDuration
                ctx.timingFunction = PolarisTheme.Motion.snapTiming
                panel.animator().setFrame(target, display: true)
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.panel.invalidateShadow() }
            })
        } else {
            panel.setFrame(target, display: true)
            panel.invalidateShadow()
        }
    }

    func move(to corner: Corner) {
        model.corner = corner
        savePlacement()
        placeAtCorner(animated: true)
    }

    private func drag(_ phase: DragPhase) {
        switch phase {
        case .changed:
            if dragStart == nil {
                dragStart = (NSEvent.mouseLocation, panel.frame.origin)
                model.dragging = true
                model.pointerExited()
                model.collapseHover()
            }
            guard let start = dragStart else { return }
            let mouse = NSEvent.mouseLocation
            panel.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x,
                                         y: start.origin.y + mouse.y - start.mouse.y))
        case .ended:
            guard dragStart != nil else { return }
            dragStart = nil
            model.dragging = false
            let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
            let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? currentScreen
            guard let screen else { return }
            displayUUID = screen.displayUUID
            model.corner = screen.corner(nearest: center)
            savePlacement()
            placeAtCorner(animated: true)
        }
    }

    /// 「ディスプレイの UUID＋隅」で覚える。そのディスプレイがなければメイン画面の同じ隅。
    private func savePlacement() {
        UserDefaults.standard.set(["display": displayUUID ?? "", "corner": model.corner.rawValue], forKey: "notePlacement")
    }

    private func restorePlacement() {
        let saved = UserDefaults.standard.dictionary(forKey: "notePlacement")
        displayUUID = (saved?["display"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? NSScreen.main?.displayUUID
        model.corner = (saved?["corner"] as? String).flatMap(Corner.init(rawValue:)) ?? .bottomRight
    }
}

enum DragPhase { case changed, ended }

/// パネルの中身。隅が上なら上寄せ、下なら下寄せにして、伸びる方向を画面の中心側にする。
struct NotePanelRoot: View {
    let model: NoteModel
    var onHeight: (CGFloat) -> Void
    var onDrag: (DragPhase) -> Void
    @FocusState private var rootFocused: Bool
    /// 付箋を掴んでいる間だけ true。取り消されて onEnded が来ないときも false に戻るので、終わりの合図に使う。
    @GestureState private var holding = false

    var body: some View {
        VStack(spacing: 0) {
            if !model.corner.isTop { Spacer(minLength: 0) }
            NoteCard()
                .fixedSize(horizontal: false, vertical: true)
                .animation(PolarisTheme.Motion.expand(model.theme.reduceMotion), value: model.expanded)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { onHeight($0) }
                .gesture(DragGesture(minimumDistance: 3)
                    .updating($holding) { _, state, _ in state = true }
                    .onChanged { _ in onDrag(.changed) }
                    .onEnded { _ in onDrag(.ended) })
                // .ended は2回来ても dragStart で1回に絞られる。
                .onChange(of: holding) { _, held in if !held { onDrag(.ended) } }
                .contextMenu { BackgroundMenuItems() }
            if model.corner.isTop { Spacer(minLength: 0) }
        }
        .frame(width: PolarisTheme.Metrics.noteWidth)
        .frame(maxHeight: .infinity)
        .overlay { NoteHintOverlay() }
        .coordinateSpace(name: NoteCard.space)
        .focusable(model.isKey && model.editing == nil)
        .focusEffectDisabled()
        .focused($rootFocused)
        .onChange(of: model.isKey) { _, key in rootFocused = key && model.editing == nil }
        .onChange(of: model.editing) { _, editing in rootFocused = model.isKey && editing == nil }
        .onKeyPress(phases: .down) { press in
            if press.key == .escape {
                model.unpinAll()
                model.keyboardIndex = nil
                model.resignKey()
                return .handled
            }
            return model.handleKey(press.key, modifiers: press.modifiers, characters: press.characters) ? .handled : .ignored
        }
        .environment(model)
        .environment(\.polaris, model.theme)
    }
}
