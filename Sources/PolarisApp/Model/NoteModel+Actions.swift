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

    func setMode(_ id: String) {
        guard id != state.today.mode.id else { return }
        run { try $0.setMode(id) }
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
    func complete(_ id: UUID) {
        guard completing == nil, let index = state.today.now.firstIndex(where: { $0.id == id }) else { return }
        let task = state.today.now[index]
        let next = index == 0 && state.today.now.count > 1 ? state.today.now[1].title : nil
        let finish: @MainActor () -> Void = { [weak self] in
            self?.run({ try $0.completeTask(id: id) }) { [weak self] _ in
                guard let self else { return }
                self.completing = nil; self.completionPhase = 0
                self.show(.undo(taskID: id, index: index, title: task.title, next: next))
            }
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

    func undo() {
        guard case .undo(let id, let index, _, _) = transient else { return }
        clearTransient()
        run { try $0.moveTask(id: id, to: .now, position: index) }
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

    /// PolarisCore に改名の操作がないので、同じ場所へ入れ直す。出所は引き継ぐ。
    func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let located: (TaskDestination, Int, Item)? = {
            if let i = state.today.now.firstIndex(where: { $0.id == id }) { return (.now, i, state.today.now[i]) }
            if let i = state.later.firstIndex(where: { $0.id == id }) { return (.later, i, state.later[i]) }
            return nil
        }()
        guard let (destination, index, task) = located, task.title != trimmed else { return }
        run { store in
            try store.removeTask(id: id)
            _ = try store.addTask(title: trimmed, to: destination, position: index, source: task.source)
        }
    }

    /// 「入れ替える…」: 選んだいまの項目をあとでの先頭へ、溢れた項目をいまの末尾へ。
    func beginSwap() {
        guard case .overflow(let id, _, _) = transient else { return }
        withAnimation(PolarisTheme.Motion.expand(theme.reduceMotion)) { swapping = id; pinned = true }
    }

    func swap(out outgoing: UUID) {
        guard let incoming = swapping else { return }
        swapping = nil
        clearTransient()
        run { store in
            _ = try store.moveTask(id: outgoing, to: .later, position: 0)
            _ = try store.moveTask(id: incoming, to: .now)
        }
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
    /// 操作できる要素の並び: 北極星 → いまの各行 → 追加 → あとで。
    var focusOrder: [FocusTarget] {
        [.northStar] + state.today.now.map { .row($0.id) } + [.add, .later]
    }

    func moveFocus(_ delta: Int) {
        let order = focusOrder
        let current = keyboardIndex ?? (delta > 0 ? -1 : order.count)
        keyboardIndex = min(max(current + delta, 0), order.count - 1)
    }

    var focusedTarget: FocusTarget? {
        guard isKey, let keyboardIndex, focusOrder.indices.contains(keyboardIndex) else { return nil }
        return focusOrder[keyboardIndex]
    }
}

enum FocusTarget: Equatable {
    case northStar, row(UUID), add, later
}

// MARK: - 朝の支度・key を外すとき
extension NoteModel {
    /// 支度の Step 3。選ばなかったいまの項目はあとでの先頭へ戻し、選んだ順にいまへ入れる。
    func applyMorning(selected: [UUID]) {
        run { store in
            let current = try store.read()
            for task in current.today.now.reversed() where !selected.contains(task.id) {
                _ = try store.moveTask(id: task.id, to: .later, position: 0)
            }
            for (index, id) in selected.prefix(3).enumerated() {
                _ = try store.moveTask(id: id, to: .now, position: index)
            }
        }
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
            if let rowID { complete(rowID) } else { return false }
        case .return:
            switch target {
            case .northStar: beginEditing(.northStar)
            case .row(let id): beginEditing(.rename(id))
            case .add: beginEditing(.add)
            case .later: toggleLater()
            case nil: return false
            }
        case .delete:
            guard let rowID else { return false }
            if command { delete(rowID) } else { sendLater(rowID) }
        default:
            if characters == "l" && !command { toggleLater() }
            else if characters == "z" && command { undo() }
            else { return false }
        }
        return true
    }
}
