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
    func endNorthStar(achieved: Bool = true) {
        guard state.today.star != nil else { return }
        run({ store -> (NorthStar, NorthStar?) in
            let result = try store.completeNorthStar(outcome: achieved ? .achieved : .dropped)
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
    func setTaskDue(_ id: UUID, _ due: String?) { run { try $0.setTaskDue(id: id, dueDate: due) } }

    /// 30秒ごとに呼ぶ。期限の「あと n日」を日付の替わり目で更新し、予約の時間が来た北極星を上げる。
    func tick() {
        let current = Date()
        if !Calendar.current.isDate(current, inSameDayAs: now) { now = current }
        surfaceScheduledStars()
    }

    /// 予約の日時になった控えを今日の北極星へ上げる。上がったら声の行と、付箋を前に出す合図で知らせる。
    func surfaceScheduledStars() {
        guard state.queuedStars.contains(where: { ($0.startsAt ?? .distantFuture) <= Date() }) else { return }
        run({ try $0.surfaceScheduledStar(now: Date()).surfaced }) { [weak self] star in
            guard let self, let star else { return }
            self.show(.starSurfaced(title: star.text))
            self.rippleToken += 1
            self.onSurface()
        }
    }
    func removeQueuedNorthStar(_ id: UUID) { run { try $0.removeNorthStar(id: id) } }
    func moveQueuedNorthStar(_ id: UUID, to position: Int) { run { try $0.moveNorthStar(id: id, position: position) } }
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

    /// いま（満杯ならあとで）かあとでに足す。満杯で溢れたら声の行で知らせる。
    func addTask(_ title: String, to destination: TaskDestination, position: Int? = nil,
                 then done: @escaping @MainActor (Placement) -> Void = { _ in }) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        run({ try $0.addTask(title: trimmed, to: destination, position: position) }) { [weak self] placement in
            if placement.overflowed { self?.show(.overflow(taskID: placement.task.id, title: trimmed, client: nil)) }
            done(placement)
        }
    }

    /// 点→✓→取り消し線→退場→繰り上がり の順に見せてから完了にする。
    /// 途中で対象が消えても書き込みに失敗しても、completing は必ず戻す。
    func complete(_ id: UUID) {
        guard completing == nil, let index = state.today.now.firstIndex(where: { $0.id == id }) else { return }
        let task = state.today.now[index]
        let next = index == 0 && state.today.now.count > 1 ? state.today.now[1].title : nil
        let finish: @MainActor () -> Void = { [weak self] in
            self?.run({ try $0.completeTask(id: id) }, then: { [weak self] _ in
                self?.show(.undo(taskID: id, index: index, title: task.title, next: next))
            }, always: { [weak self] in
                self?.completing = nil
                self?.completionPhase = 0
            })
        }
        if theme.reduceMotion {
            completing = id; completionPhase = 2
            finish()
            return
        }
        completing = id
        withAnimation(PolarisTheme.Motion.checkFill) { completionPhase = 1 }
        _Concurrency.Task { @MainActor [weak self] in
            try? await _Concurrency.Task.sleep(for: .milliseconds(120))
            guard let self else { return }
            withAnimation(PolarisTheme.Motion.strike(false)) { self.completionPhase = 2 }
            try? await _Concurrency.Task.sleep(for: .milliseconds(200))
            finish()
        }
    }

    /// 元の位置へ戻す。そのあいだにいまが埋まっていたら、あとでに入ったことを知らせる。
    func undo() {
        guard case .undo(let id, let index, let title, _) = transient else { return }
        clearTransient()
        run({ try $0.moveTask(id: id, to: .now, position: index) }) { [weak self] placement in
            if placement.overflowed { self?.show(.overflow(taskID: id, title: title, client: nil)) }
        }
    }

    func makeLead(_ id: UUID) {
        run { try $0.moveTask(id: id, to: .now, position: 0) }
    }

    func sendLater(_ id: UUID) {
        run { try $0.moveTask(id: id, to: .later, position: 0) }
    }

    func moveToNow(_ id: UUID) {
        guard !nowFull else { return }
        run { try $0.moveTask(id: id, to: .now) }
    }

    func reorder(_ id: UUID, to position: Int) {
        guard let from = state.today.now.firstIndex(where: { $0.id == id }), from != position else { return }
        run { try $0.moveTask(id: id, to: .now, position: position) }
    }

    func delete(_ id: UUID) {
        run { try $0.removeTask(id: id) }
    }

    /// 名前だけを変える。id と位置はストア側で保たれる。
    func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let task = (state.today.now + state.later).first(where: { $0.id == id }), task.title != trimmed else { return }
        run { try $0.renameTask(id: id, title: trimmed) }
    }

    /// 「入れ替える…」: 選んだいまの項目をあとでの先頭へ、溢れた項目をいまの末尾へ。
    func beginSwap() {
        guard case .overflow(let id, _, _) = transient else { return }
        withAnimation(PolarisTheme.Motion.expand(theme.reduceMotion)) { swapping = id; pinned = true }
        keyboardIndex = keyboardIndex.map { _ in focusOrder.firstIndex { if case .swapTarget = $0 { true } else { false } } ?? 0 }
    }

    /// 本命とは入れ替えない（主役は1つ）。本命と替えたいときは行メニューの「本命にする」を使う。
    func swap(out outgoing: UUID) {
        guard let incoming = swapping, state.today.now.first?.id != outgoing else { return }
        swapping = nil
        clearTransient()
        run { try $0.swapTasks(out: outgoing, in: incoming) }
    }

    func cancelSwap() {
        guard swapping != nil else { return }
        withAnimation(PolarisTheme.Motion.voiceSwap(theme.reduceMotion)) { swapping = nil }
        clearTransient()
    }

    // MARK: その場の編集
    func beginEditing(_ target: Editing) {
        switch target {
        case .northStar: draft = state.today.northStar
        case .rename(let id): draft = (state.today.now + state.later).first { $0.id == id }?.title ?? ""
        case .add: draft = ""
        }
        withAnimation(PolarisTheme.Motion.expand(theme.reduceMotion)) { editing = target }
        requestKey()
    }

    func commitEditing() {
        guard let editing else { return }
        let text = draft
        switch editing {
        case .northStar: setNorthStar(text)
        case .rename(let id): rename(id, to: text)
        case .add: addTask(text, to: .now)
        }
        if case .add = editing, !text.trimmingCharacters(in: .whitespaces).isEmpty {
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
    /// 操作できる要素の並び: 北極星 → いまの各行 →（入れ替え中なら各行の入れ替え）→ 追加（全部完了ならその操作）
    /// → あとで →（開いていれば）あとでの各行 → 声の行のボタン。
    var focusOrder: [FocusTarget] {
        var order: [FocusTarget] = [.northStar]
        if showsStarQueue { order.append(.starQueue) }
        order += state.today.now.map { .row($0.id) }
        if swapping != nil { order += state.today.now.dropFirst().map { .swapTarget($0.id) } }
        if isAllDone && editing != .add {
            order += (0..<allDoneActionCount).map { .allDoneAction($0) }
        } else {
            order.append(.add)
        }
        order.append(.later)
        if laterOpen { order += state.later.map { .laterRow($0.id) } }
        order += (0..<voiceActionCount).map { .voiceAction($0) }
        return order
    }

    /// 展開中に北極星のすぐ下へ出す控えの行。今日の北極星か控えがあるときだけ。
    var showsStarQueue: Bool { expanded && (state.today.star != nil || !state.queuedStars.isEmpty) }

    /// 控えの行のボタン: 今日の北極星があれば［達成した］、なければ控えの先頭を［これにする］。
    func performStarQueueAction() {
        if state.today.star != nil { endNorthStar() }
        else if let next = state.queuedStars.first { activateNorthStar(next.id) }
    }

    /// 全部完了のときの操作: あとでが空なら［＋ 追加］［今日はここまで］、あれば［今日はここまで］だけ。
    var allDoneActionCount: Int { state.later.isEmpty ? 2 : 1 }

    func performAllDoneAction(_ index: Int) {
        if state.later.isEmpty && index == 0 { beginEditing(.add) } else { closeDay() }
    }

    /// 声の行に出ているボタンの数（左から順）。透過中は出さない。
    var voiceActionCount: Int {
        guard !clickThrough || optionPeek else { return 0 }
        switch voice {
        case .mode, .transient(.error), .transient(.modeChanged), .transient(.starSurfaced): return 0
        case .detour: return 2
        case .transient(.undo), .transient(.overflow), .transient(.starEnded), .banner: return 1
        }
    }

    func performVoiceAction(_ index: Int) {
        switch voice {
        case .detour(let detour):
            if index == 0 { DetourActions.hide(detour, model: self) } else { DetourActions.snooze(detour, model: self) }
        case .transient(.undo): undo()
        case .transient(.starEnded): undoStarEnded()
        case .transient(.overflow): swapping == nil ? beginSwap() : cancelSwap()
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

    /// ⌃⌥O で最初に置く場所。寄り道が出ていれば［{App}を隠す］、なければ本命の行。
    var initialKeyboardIndex: Int {
        if case .detour = voice, let i = focusOrder.firstIndex(of: .voiceAction(0)) { return i }
        if let lead = state.today.now.first, let i = focusOrder.firstIndex(of: .row(lead.id)) { return i }
        return 0
    }
}

enum FocusTarget: Equatable {
    case northStar, starQueue, row(UUID), add, later
    case voiceAction(Int), laterRow(UUID), swapTarget(UUID), allDoneAction(Int)
}

// MARK: - 朝の支度・key を外すとき
extension NoteModel {
    /// 支度の Step 3。選ばなかったいまの項目はあとでの先頭へ戻し、選んだ順にいまへ入れる。
    func applyMorning(selected: [UUID]) {
        let chosen = Array(selected.prefix(3))
        run { try $0.arrangeMorning(selected: chosen) }
    }

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
        case .rename(let id): rename(id, to: text)
        case .add: addTask(text, to: .now)
        }
        withAnimation(PolarisTheme.Motion.collapse(theme.reduceMotion)) { self.editing = nil }
        draft = ""
    }

    /// 付箋が key のときのキー操作（design.md 6章）。処理したら true。
    func handleKey(_ key: KeyEquivalent, modifiers: EventModifiers, characters: String) -> Bool {
        let command = modifiers.contains(.command)
        let target = focusedTarget
        let rowID: UUID? = { if case .row(let id) = target { return id }; return nil }()
        switch key {
        case .upArrow:
            if command, let rowID { makeLead(rowID) } else { moveFocus(-1) }
        case .downArrow: moveFocus(1)
        case .tab: moveFocus(modifiers.contains(.shift) ? -1 : 1)
        case .space:
            if let rowID { complete(rowID) } else { return activate(target) }
        case .return:
            switch target {
            case .northStar: beginEditing(.northStar)
            case .row(let id): beginEditing(.rename(id))
            case .add: beginEditing(.add)
            case .later: toggleLater()
            default: return activate(target)
            }
        case .delete:
            if let rowID {
                if command { delete(rowID) } else { sendLater(rowID) }
            } else if case .laterRow(let id) = target, command {
                delete(id)
            } else { return false }
        case .escape where swapping != nil:
            cancelSwap()
        default:
            if characters == "l" && !command { toggleLater() }
            else if characters == "z" && command {
                if case .transient(.starEnded) = voice { undoStarEnded() } else { undo() }
            }
            else { return false }
        }
        return true
    }

    /// 行以外のボタン（声の行・入れ替え・あとでの行・全部完了）を ⏎ / Space で押す。
    private func activate(_ target: FocusTarget?) -> Bool {
        switch target {
        case .voiceAction(let i): performVoiceAction(i)
        case .starQueue: performStarQueueAction()
        case .swapTarget(let id): swap(out: id)
        case .laterRow(let id): moveToNow(id)
        case .allDoneAction(let i): performAllDoneAction(i)
        default: return false
        }
        return true
    }
}
