import AppKit
import PolarisCore
import SwiftUI

/// 付箋・メニュー・キーボードから呼ぶ操作。
extension NoteModel {
    func setNorthStar(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != state.today.northStar else { return }
        run { try $0.setNorthStar(trimmed) }
    }

    // MARK: 北極星の控え

    /// 今日の北極星を終えて、控えの先頭を繰り上げる。
    func endNorthStar(id: UUID, achieved: Bool = true) {
        guard state.today.star?.id == id else { return }
        run({ store -> (NorthStar, NorthStar?) in
            let result = try store.completeNorthStar(id: id, outcome: achieved ? .achieved : .dropped)
            return (result.completed, result.next)
        }) { [weak self] completed, next in
            guard let self else { return }
            self.show(.starEnded(starID: completed.id, title: completed.text, next: next?.text, achieved: achieved))
            if achieved && self.celebrates { self.onCelebrate() }
        }
    }

    /// 終えたのを取り消す。ログから控えへ戻して今日に出すと、繰り上がった分は控えの先頭へ戻る。
    func undoStarEnded() {
        guard case .starEnded(let id, _, _, _) = transient else { return }
        clearTransient()
        run { try $0.restoreNorthStar(id: id) }
    }

    func activateNorthStar(_ id: UUID) { run { try $0.activateNorthStar(id: id) } }
    func setNorthStarDue(_ id: UUID, _ due: String?) { run { try $0.setNorthStarDue(id: id, dueDate: due) } }
    func setNorthStarStart(_ id: UUID, _ date: Date?) { run { try $0.setNorthStarStart(id: id, startsAt: date) } }
    func renameNorthStar(_ id: UUID, _ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        run { try $0.renameNorthStar(id: id, text: text) }
    }

    /// 30秒ごとに呼ぶ。期限の「あと n日」を日付の替わり目で更新し、予約の時間が来た北極星を上げる。
    func tick() {
        let current = Date()
        // 期限の「あと何時間」を進めるため、分が変わったら now を進める。
        if Int(current.timeIntervalSince1970 / 60) != Int(now.timeIntervalSince1970 / 60) { now = current }
        surfaceScheduledStars()
    }

    /// 予約の日時になった控えを今日の北極星へ上げる。上がったら声の行と、付箋を前に出す合図で知らせる。
    func surfaceScheduledStars() {
        guard !surfacing, state.queuedStars.contains(where: { ($0.startsAt ?? .distantFuture) <= Date() }) else { return }
        surfacing = true
        run({ try $0.surfaceScheduledStar(now: Date()).surfaced }, then: { [weak self] star in
            guard let self, let star else { return }
            self.show(.starSurfaced(title: star.text))
            self.onSurface()
        }, always: { [weak self] in self?.surfacing = false })
    }
    func removeQueuedNorthStar(_ id: UUID) { run { try $0.removeNorthStar(id: id) } }
    func moveQueuedNorthStar(_ id: UUID, to position: Int, always: @escaping @MainActor () -> Void = {}) {
        run({ try $0.moveNorthStar(id: id, position: position) }, always: always)
    }
    func reopenNorthStar(_ id: UUID) { run { try $0.reopenNorthStar(id: id) } }

    /// 控えの末尾に足す。今日の北極星は変えない。
    func queueNorthStar(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        run { _ = try $0.addNorthStar(text: trimmed) }
    }

    func setMode(_ id: String) {
        guard id != state.today.mode.id else { return }
        run { try $0.setMode(id) }
    }

    // MARK: モードの編集（設定画面）

    /// 名前だけを変える。寄り道のアプリの変更と並んでも互いに消さないよう、ストアで最新のモードに当てる。
    func renameMode(_ id: String, to label: String) {
        guard modes.first(where: { $0.id == id })?.label != label else { return }
        run { try $0.renameMode(id: id, label: label) }
    }

    /// 寄り道のアプリを足し引きする。差分だけを送る。
    func updateAvoidApps(_ id: String, add: [String] = [], remove: [String] = []) {
        guard !add.isEmpty || !remove.isEmpty else { return }
        run { try $0.updateAvoidApps(id: id, add: add, remove: remove) }
    }

    /// 新しいモードを末尾に足し、その id を返す。見た目は既定と同じ控えめな glyph にする。
    @discardableResult func addMode(label: String) -> String {
        let mode = Mode(id: "mode-\(UUID().uuidString.prefix(8).lowercased())", label: label, symbol: "circle", tint: "slate")
        run { try $0.upsertMode(mode) }
        return mode.id
    }

    func removeMode(_ id: String) {
        run { try $0.removeMode(id: id) }
    }

    // MARK: その場の編集
    func beginEditing(_ target: Editing) {
        switch target {
        case .northStar: draft = state.today.northStar
        case .queueStar: draft = ""
        }
        withAnimation(PolarisTheme.Motion.expand(theme.reduceMotion)) { editing = target }
        requestKey()
    }

    func commitEditing() {
        guard let editing else { return }
        let text = draft
        switch editing {
        case .northStar: setNorthStar(text)
        case .queueStar: queueNorthStar(text)
        }
        // 続けて足すものは入力欄を残す。控えはいま足した分で満杯になるなら閉じる。
        let queueFull = editing == .queueStar && state.queuedStars.count + 1 >= TextRules.starQueueMax
        if editing == .queueStar, !queueFull, !text.trimmingCharacters(in: .whitespaces).isEmpty {
            draft = "" // 続けて足せるように入力欄は残す
            return
        }
        endEditing()
    }

    func endEditing() {
        withAnimation(PolarisTheme.Motion.collapse(theme.reduceMotion)) { editing = nil }
        draft = ""
        if !pinned { resignKey() }
    }

    // MARK: キーボード（付箋が key のとき）
    var focusOrder: [FocusTarget] {
        var order: [FocusTarget] = [.northStar]
        if state.today.star != nil || !state.queuedStars.isEmpty { order.append(.starQueue) }
        order.append(.starsList)
        if state.queuedStars.count < TextRules.starQueueMax { order.append(.queueStar) }
        order += (0..<voiceActionCount).map { .voiceAction($0) }
        return order
    }

    /// 控えの行のボタン: 今日の北極星があれば［達成した］、なければ控えの先頭を［これにする］。
    func performStarQueueAction() {
        if let star = state.today.star { endNorthStar(id: star.id) }
        else if let next = state.queuedStars.first { activateNorthStar(next.id) }
    }

    /// 声の行に出ているボタンの数（左から順）。透過中は出さない。
    var voiceActionCount: Int {
        guard interactive else { return 0 }
        switch voice {
        case .mode, .transient(.error), .transient(.modeChanged), .transient(.starSurfaced): return 0
        case .detour: return 2
        case .transient(.starEnded), .banner: return 1
        }
    }

    func performVoiceAction(_ index: Int) {
        switch voice {
        case .detour(let detour):
            if index == 0 { DetourActions.hide(detour, model: self) } else { DetourActions.snooze(detour, model: self) }
        case .transient(.starEnded): undoStarEnded()
        case .banner: dismissBanner()
        case .mode, .transient(.error), .transient(.modeChanged), .transient(.starSurfaced): break
        }
    }

    func moveFocus(_ delta: Int) {
        let order = focusOrder
        let current = keyboardIndex.map { min($0, order.count - 1) } ?? (delta > 0 ? -1 : order.count)
        keyboardIndex = min(max(current + delta, 0), order.count - 1)
    }

    var focusedTarget: FocusTarget? {
        guard isKey, let keyboardIndex, focusOrder.indices.contains(keyboardIndex) else { return nil }
        return focusOrder[keyboardIndex]
    }

    /// ⌃⌥O で最初に置く場所。寄り道が出ていれば［{App}を隠す］、なければ北極星。
    var initialKeyboardIndex: Int {
        if case .detour = voice, let i = focusOrder.firstIndex(of: .voiceAction(0)) { return i }
        return 0
    }
}

enum FocusTarget: Equatable {
    case northStar, starQueue, starsList, queueStar
    case voiceAction(Int)
}

// MARK: - 朝の支度・key を外すとき
extension NoteModel {
    /// 読めない state.json を退避して作り直す（メニューから）。
    func resetCorruptState() {
        run { _ = try $0.resetCorruptState() }
    }

    /// 付箋が key を失ったら、入力中の内容は捨てずに保存して閉じる。
    func finishEditingOnResign() {
        guard let editing else { return }
        let text = draft
        switch editing {
        case .northStar: setNorthStar(text)
        case .queueStar: queueNorthStar(text)
        }
        withAnimation(PolarisTheme.Motion.collapse(theme.reduceMotion)) { self.editing = nil }
        draft = ""
    }

    func handleKey(_ key: KeyEquivalent, modifiers: EventModifiers, characters: String) -> Bool {
        switch key {
        case .upArrow: moveFocus(-1)
        case .downArrow: moveFocus(1)
        case .tab: moveFocus(modifiers.contains(.shift) ? -1 : 1)
        case .space, .return:
            switch focusedTarget {
            case .northStar: beginEditing(.northStar)
            case .starQueue: performStarQueueAction()
            case .starsList: (NSApp.delegate as? AppCoordinator)?.showStars()
            case .queueStar: beginEditing(.queueStar)
            case .voiceAction(let i): performVoiceAction(i)
            case nil: return false
            }
        default:
            if characters == "z", modifiers.contains(.command), case .transient(.starEnded) = voice { undoStarEnded() }
            else { return false }
        }
        return true
    }
}
