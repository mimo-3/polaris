import AppKit
import PolarisCore
import SwiftUI

/// 付箋・シート・メニューバー・ショートカット・寄り道検知をつなぐ。
@MainActor
final class AppCoordinator: NSObject, NSApplicationDelegate {
    private(set) var model: NoteModel!
    private(set) var note: NotePanelController!
    private var morning: AuxPanelController!
    private var quickEdit: AuxPanelController!
    private var mini: AuxPanelController!
    private let celebration = CelebrationController()
    private var surfaceTimer: Timer?
    private var statusMenu: StatusMenu!
    private var detour: DetourMonitor!
    private var settingsWindow: NSWindow?
    private var starsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 最初の状態は監視の初回通知（別キュー）で入る。ここで同期的に読むと、MCP の書き込み中に起動が止まる。
        model = NoteModel(state: NoteModel.placeholderState(), store: PolarisStore())
        model.theme = .current()
        note = NotePanelController(model: model)

        let place: () -> (NSScreen?, Corner) = { [weak self] in (self?.note.panel.screen, self?.model.corner ?? .bottomRight) }
        morning = AuxPanelController(width: PolarisTheme.Metrics.sheetWidth, keyable: true, place: place)
        quickEdit = AuxPanelController(width: PolarisTheme.Metrics.quickEditWidth, keyable: true, place: place)
        mini = AuxPanelController(width: PolarisTheme.Metrics.noteWidth, keyable: false, clickThrough: true, place: place)

        wireModel()
        statusMenu = StatusMenu(app: self)
        note.onVisibilityChanged = { [weak self] hidden in self?.statusMenu.updateIcon(hidden: hidden) }
        registerHotKeys()
        startDetourMonitor()
        observeAccessibility()

        note.show()
        model.startObserving()
    }

    private func wireModel() {
        model.onSurface = { [weak self] in
            guard let self else { return }
            // 隠していても、予約の時間になったら付箋を出す。
            if self.note.isHidden { self.note.show() }
        }
        // 予約の北極星は分単位で決めるので、30秒ごとに見れば十分。
        surfaceTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.tick() }
        }
        model.onCelebrate = { [weak self] in
            guard let self, self.note.panel.isVisible else { return }
            self.celebration.burst(from: self.note.panel.frame, reduceMotion: self.model.theme.reduceMotion,
                                   sound: self.model.celebrationSound)
        }
        model.onDayChanged = { [weak self] in
            guard let self else { return }
            if self.note.isHidden { self.note.show() }
            self.showMorningIfNeeded()
        }
        model.announce = { text, priority in
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: text, .priority: priority.rawValue])
        }
    }

    // MARK: 朝の支度

    /// 初回起動とロールオーバー直後に1回だけ、key にしないで出す。
    private func showMorningIfNeeded() {
        let date = model.today.date
        guard !date.isEmpty, UserDefaults.standard.string(forKey: "morningShownDate") != date else { return }
        UserDefaults.standard.set(date, forKey: "morningShownDate")
        showMorning(key: false)
    }

    func showMorning(key: Bool) {
        quickEdit.close()
        let view = MorningSheetView(state: model.state) { [weak self] in self?.morning.close() }
            .environment(model)
        morning.present(view, theme: model.theme, key: key)
    }

    // MARK: クイック編集

    func showQuickEdit(_ focus: QuickEditView.Field) {
        let view = QuickEditView(state: model.state, focus: focus) { [weak self] in self?.quickEdit.close() }
            .environment(model)
        quickEdit.present(view, theme: model.theme, key: true)
    }

    // MARK: 設定

    private var settingsHeight: CGFloat { min(640, (NSScreen.main?.visibleFrame.height ?? 800) - 80) }

    func showSettings() {
        if settingsWindow == nil {
            // 中身はスクロールするので、窓は画面に収まる高さで固定し、縦にだけ伸び縮みさせる。
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsView.width, height: settingsHeight),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Polaris の設定"
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: SettingsView.width, height: 360)
            window.contentMaxSize = NSSize(width: SettingsView.width, height: .greatestFiniteMagnitude)
            settingsWindow = window
        }
        let view = SettingsView(conflicts: HotKeyCenter.shared.conflicts)
            .environment(model)
            .environment(\.polaris, model.theme)
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = []
        settingsWindow?.contentViewController = controller
        settingsWindow?.setContentSize(NSSize(width: SettingsView.width, height: settingsHeight))
        settingsWindow?.center()
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: 北極星の控えと振り返り

    func showStars() {
        if starsWindow == nil {
            // 中身はスクロールするので、窓は画面に収まる高さで固定し、縦にだけ伸び縮みさせる。
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: StarsView.width, height: settingsHeight),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = Copy.starsWindowTitle
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: StarsView.width, height: 360)
            window.contentMaxSize = NSSize(width: StarsView.width, height: .greatestFiniteMagnitude)
            let view = StarsView()
                .environment(model)
                .environment(\.polaris, model.theme)
            let controller = NSHostingController(rootView: view)
            controller.sizingOptions = []
            window.contentViewController = controller
            window.setContentSize(NSSize(width: StarsView.width, height: settingsHeight))
            window.center()
            starsWindow = window
        }
        NSApp.activate()
        starsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: ショートカット

    private func registerHotKeys() {
        let hk = HotKeyCenter.shared
        hk.register(.editNorthStar) { [weak self] in self?.showQuickEdit(.northStar) }
        hk.register(.showStars) { [weak self] in self?.showStars() }
        hk.register(.focusNote) { [weak self] in self?.note.focusForKeyboard() }
        hk.register(.toggleHidden) { [weak self] in self?.note.toggleVisibility() }
        hk.register(.toggleClickThrough) { [weak self] in
            guard let self else { return }
            self.note.setClickThrough(!self.model.clickThrough)
        }
    }

    // MARK: 寄り道

    private func startDetourMonitor() {
        detour = DetourMonitor(model: model)
        DetourActions.monitor = detour
        detour.isHidden = { [weak self] in self?.note.isHidden ?? false }
        detour.isSnoozedHidden = { [weak self] in self?.note.hiddenUntil != nil }
        detour.showWhileHidden = { [weak self] in
            guard let self else { return }
            self.mini.present(MiniDetourView().environment(self.model), theme: self.model.theme, key: false, autoClose: 12)
        }
        detour.hideMini = { [weak self] in self?.mini.close() }
        detour.start()
    }

    // MARK: アクセシビリティ

    private func observeAccessibility() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.theme = .current()
                self.note.setClickThrough(self.model.clickThrough)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// 付箋の背景で右クリックしたときのメニュー（メニューバーと同じ操作）。
struct BackgroundMenuItems: View {
    var body: some View {
        if let app = NSApp.delegate as? AppCoordinator {
            Button(Copy.editNorthStar) { app.showQuickEdit(.northStar) }
            Button(Copy.redoMorning) { app.showMorning(key: true) }
            Button(Copy.starsWindowMenu) { app.showStars() }
            Divider()
            Button(Copy.hideNote) { app.note.hide() }
            Button(Copy.hide15) { app.note.hide(for: 15) }
            Button(Copy.clickThrough) { app.note.setClickThrough(!app.model.clickThrough) }
            Menu(Copy.modeMenu) {
                ForEach(app.model.modes) { mode in Button(mode.label) { app.model.setMode(mode.id) } }
            }
            Menu(Copy.cornerMenu) {
                ForEach(Corner.menuOrder, id: \.self) { corner in Button(corner.label) { app.note.move(to: corner) } }
            }
            Divider()
            Button(Copy.settings) { app.showSettings() }
        }
    }
}
