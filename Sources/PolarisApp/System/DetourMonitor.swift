import AppKit

/// 前面アプリを見て、いまのモードの avoidApps が来たら声の行で知らせる。止めはしない。
@MainActor
final class DetourMonitor {
    static let interval: TimeInterval = 5 * 60
    private let model: NoteModel
    /// 付箋を隠しているときに、簡易パネルを出してもらう。
    var showWhileHidden: () -> Void = {}
    var hideMini: () -> Void = {}
    /// 「15分だけ隠す」中かどうか。
    var isSnoozedHidden: () -> Bool = { false }
    var isHidden: () -> Bool = { false }
    private var lastShown: [String: Date] = [:]
    private var observer: NSObjectProtocol?

    init(model: NoteModel) {
        self.model = model
    }

    func start() {
        stop()
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            let name = app?.localizedName
            let pid = app?.processIdentifier ?? 0
            MainActor.assumeIsolated { self?.frontmostChanged(bundleID: bundleID, name: name, pid: pid) }
        }
    }

    /// 監視をやめる。作り直すときに呼ぶ。
    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
    }

    /// 「5分だけ見る」: そのアプリについて5分間は出さない。
    func snooze(_ bundleID: String) {
        lastShown[bundleID] = Date()
    }

    private func frontmostChanged(bundleID: String?, name: String?, pid: pid_t) {
        guard bundleID != Bundle.main.bundleIdentifier else { return }
        // 前面アプリが変わったら、出ていた知らせは戻す。
        if model.detour != nil, model.detour?.bundleID != bundleID {
            model.clearDetour()
            hideMini()
        }
        let mode = model.mode
        guard let bundleID, mode.avoidApps.contains(bundleID), !isSnoozedHidden() else { return }
        if let last = lastShown[bundleID], Date().timeIntervalSince(last) < Self.interval { return }
        lastShown[bundleID] = Date()
        let detour = Detour(bundleID: bundleID, appName: name ?? AppNames.name(for: bundleID), pid: pid, mode: mode)
        model.showDetour(detour)
        if isHidden() { showWhileHidden() }
    }
}

/// 声の行のボタン。
@MainActor
enum DetourActions {
    static weak var monitor: DetourMonitor?

    /// 隠すだけ。終了もブロックもしない。隠すと直前のアプリが前面に戻る。
    static func hide(_ detour: Detour, model: NoteModel) {
        NSRunningApplication(processIdentifier: detour.pid)?.hide()
        model.clearDetour()
    }

    static func snooze(_ detour: Detour, model: NoteModel) {
        monitor?.snooze(detour.bundleID)
        model.clearDetour()
    }
}
