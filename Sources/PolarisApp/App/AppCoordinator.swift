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
    private var statusMenu: StatusMenu!
    private var detour: DetourMonitor!
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = PolarisStore()
        let initial: AppState
        var failed = false
        do { initial = try store.read() } catch { initial = NoteModel.placeholderState(); failed = true }
        model = NoteModel(state: initial, store: store)
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
        if failed { model.show(.error(Copy.loadFailed)) }
        showMorningIfNeeded()
    }

    private func wireModel() {
        model.requestMorning = { [weak self] in self?.showMorning(key: true) }
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

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 480),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Polaris の設定"
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        let view = SettingsView(conflicts: HotKeyCenter.shared.conflicts).environment(\.polaris, model.theme)
        settingsWindow?.contentView = NSHostingView(rootView: view)
        settingsWindow?.center()
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: ショートカット

    private func registerHotKeys() {
        let hk = HotKeyCenter.shared
        hk.register(.editNorthStar) { [weak self] in self?.showQuickEdit(.northStar) }
        hk.register(.addTask) { [weak self] in self?.showQuickEdit(.add) }
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
            Button(Copy.addTask) { app.showQuickEdit(.add) }
            Button(Copy.redoMorning) { app.showMorning(key: true) }
            Divider()
            Button(Copy.hideNote) { app.note.hide() }
            Button(Copy.hide15) { app.note.hide(for: 15) }
            Button(Copy.clickThrough) { app.note.setClickThrough(!app.model.clickThrough) }
            Menu(Copy.modeMenu) {
                ForEach(Mode.defaults) { mode in Button(mode.label) { app.model.setMode(mode.id) } }
            }
            Menu(Copy.cornerMenu) {
                ForEach(Corner.menuOrder, id: \.self) { corner in Button(corner.label) { app.note.move(to: corner) } }
            }
            Divider()
            Button(Copy.settings) { app.showSettings() }
        }
    }
}
