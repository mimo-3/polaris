import AppKit
import Observation
import PolarisCore
import SwiftUI

/// 付箋に出す状態と、ユーザー操作を受ける窓口。ストア操作はメインスレッド外で行う。
@MainActor @Observable
final class NoteModel {
    // MARK: 永続状態
    private(set) var state: AppState
    private(set) var loadFailed = false
    @ObservationIgnored let store: PolarisStore?

    // MARK: 表示環境
    var theme = ThemeContext()
    var corner: Corner = .bottomRight

    // MARK: 付箋の UI 状態
    var pinned = false
    var hoverOpen = false
    var laterOpen = false
    var editing: Editing?
    var draft = ""
    var swapping: UUID?
    var clickThrough = false
    var optionPeek = false
    var isKey = false
    var keyboardIndex: Int?
    var dragging = false
    var dayClosedDate: String?
    var hidden = false

    // MARK: 完了の動き
    var completing: UUID?
    var completionPhase = 0 // 0: 点 / 1: ✓ / 2: 取り消し線まで
    var rippleToken = 0
    /// スナップショット用。波紋の途中を固定して描く。
    var snapshotRipple: CGFloat?

    // MARK: 声の行
    var detour: Detour?
    var transient: Transient?
    var dismissedBanner: Banner?
    var now = Date()

    // MARK: ホバー（パネルからポインタ位置を受ける。非アクティブなアプリでも確実に拾うため自前で判定する）
    var pointer: CGPoint? { didSet { updateHoveredRow() } }
    var rowFrames: [UUID: CGRect] = [:] { didSet { updateHoveredRow() } }
    var hoveredRow: UUID?

    // MARK: パネルへの依頼
    @ObservationIgnored var requestKey: () -> Void = {}
    @ObservationIgnored var resignKey: () -> Void = {}
    @ObservationIgnored var onDayChanged: () -> Void = {}
    @ObservationIgnored var requestMorning: () -> Void = {}
    @ObservationIgnored var onStateApplied: () -> Void = {}
    @ObservationIgnored var announce: (String, NSAccessibilityPriorityLevel) -> Void = { _, _ in }

    @ObservationIgnored private var hoverTimer: _Concurrency.Task<Void, Never>?
    @ObservationIgnored private var transientTimer: _Concurrency.Task<Void, Never>?
    @ObservationIgnored private var detourTimer: _Concurrency.Task<Void, Never>?
    @ObservationIgnored private var clock: _Concurrency.Task<Void, Never>?

    init(state: AppState, store: PolarisStore?) {
        self.state = state
        self.store = store
        dayClosedDate = UserDefaults.standard.string(forKey: "dayClosedDate")
    }

    static func placeholderState() -> AppState {
        AppState(today: Day(date: ""))
    }

    // MARK: 派生値
    var today: Day { state.today }
    var mode: Mode { state.today.mode }
    var lead: Item? { state.today.now.first }
    var expanded: Bool {
        guard !clickThrough || optionPeek else { return false }
        return pinned || hoverOpen || editing != nil || swapping != nil
    }
    var isDayClosed: Bool { dayClosedDate == state.today.date && !state.today.date.isEmpty }
    var isAllDone: Bool { state.today.now.isEmpty && !state.today.done.isEmpty }
    var nowFull: Bool { state.today.now.count >= 3 }
    var visibleBanner: Banner? {
        guard let banner = state.banner, banner != dismissedBanner, banner.expiresAt > now else { return nil }
        return banner
    }
    var voice: Voice {
        Voice.resolve(detour: detour, transient: transient, banner: visibleBanner, holdBanner: completing != nil)
    }

    private func updateHoveredRow() {
        guard !theme.snapshot else { return }
        guard let pointer, !dragging else { if hoveredRow != nil { hoveredRow = nil }; return }
        let hit = rowFrames.first { $0.value.insetBy(dx: -8, dy: -4).contains(pointer) }?.key
        if hit != hoveredRow { hoveredRow = hit }
    }

    // MARK: 状態の反映
    func startObserving() {
        guard let store else { return }
        _Concurrency.Task { @MainActor [weak self] in
            do {
                for try await next in store.changes() { self?.apply(next) }
            } catch {
                self?.loadFailed = true
                self?.show(.error(Copy.loadFailed))
            }
        }
        clock = _Concurrency.Task { @MainActor [weak self] in
            while !_Concurrency.Task.isCancelled {
                try? await _Concurrency.Task.sleep(for: .seconds(1))
                self?.now = Date()
            }
        }
    }

    func apply(_ next: AppState) {
        guard next != state else { return }
        let dayChanged = next.today.date != state.today.date && !state.today.date.isEmpty
        let leadChanged = next.today.now.first?.id != state.today.now.first?.id
        let animation: Animation? = leadChanged ? PolarisTheme.Motion.promote(theme.reduceMotion) : .easeOut(duration: 0.2)
        let newBanner = next.banner != nil && next.banner != state.banner ? next.banner : nil
        withAnimation(animation) { state = next }
        if let newBanner { announce("\(newBanner.text)。\(Copy.from(Copy.clientName(newBanner.from)))", .low) }
        loadFailed = false
        if let swapping, !next.later.contains(where: { $0.id == swapping }) { self.swapping = nil }
        if case .overflow(let id, _, _) = transient, !next.later.contains(where: { $0.id == id }) { clearTransient() }
        if dayChanged {
            pinned = false; laterOpen = false; editing = nil
            onDayChanged()
        }
        onStateApplied()
    }

    /// ストア操作をメインスレッド外で行い、終わったら最新状態を反映する。
    func run<T: Sendable>(_ op: @escaping @Sendable (PolarisStore) throws -> T,
                          then done: @escaping @MainActor (T) -> Void = { _ in }) {
        guard let store else { return }
        _Concurrency.Task { @MainActor [weak self] in
            let result = await _Concurrency.Task.detached(priority: .userInitiated) {
                Result { () throws -> (T, AppState) in
                    let value = try op(store)
                    return (value, try store.read())
                }
            }.value
            guard let self else { return }
            switch result {
            case .success(let (value, state)):
                self.apply(state)
                done(value)
            case .failure:
                self.show(.error(Copy.saveFailed))
            }
        }
    }

    // MARK: 声の行
    func show(_ t: Transient) {
        withAnimation(PolarisTheme.Motion.voiceSwap(theme.reduceMotion)) { transient = t }
        scheduleTransientExpiry(after: t.duration)
        switch t {
        case .undo(_, _, let title, let next):
            announce(next.map { "\(title)を完了にした。次の本命は\($0)" } ?? "\(title)を完了にした。", .medium)
        case .overflow(_, let title, _): announce(Copy.overflow(title), .medium)
        case .error(let message): announce(message, .high)
        }
    }

    private func scheduleTransientExpiry(after seconds: TimeInterval) {
        transientTimer?.cancel()
        transientTimer = _Concurrency.Task { @MainActor [weak self] in
            try? await _Concurrency.Task.sleep(for: .seconds(seconds))
            guard let self, !_Concurrency.Task.isCancelled else { return }
            // 4件目の知らせはホバー中は消さない。
            if case .overflow = self.transient, self.pointer != nil || self.swapping != nil {
                self.scheduleTransientExpiry(after: 1)
                return
            }
            self.clearTransient()
        }
    }

    func clearTransient() {
        transientTimer?.cancel()
        withAnimation(PolarisTheme.Motion.voiceSwap(theme.reduceMotion)) { transient = nil }
    }

    func dismissBanner() {
        withAnimation(PolarisTheme.Motion.voiceSwap(theme.reduceMotion)) { dismissedBanner = state.banner }
    }

    func showDetour(_ detour: Detour) {
        withAnimation(PolarisTheme.Motion.voiceSwap(theme.reduceMotion)) { self.detour = detour }
        if !theme.reduceMotion { rippleToken += 1 }
        let star = state.today.northStar.isEmpty ? "" : "北極星、\(state.today.northStar)"
        announce("今日は\(detour.mode.label)。\(detour.appName)が前面にある。\(star)", .medium)
        detourTimer?.cancel()
        detourTimer = _Concurrency.Task { @MainActor [weak self] in
            try? await _Concurrency.Task.sleep(for: .seconds(12))
            guard !_Concurrency.Task.isCancelled else { return }
            self?.clearDetour()
        }
    }

    func clearDetour() {
        detourTimer?.cancel()
        guard detour != nil else { return }
        withAnimation(PolarisTheme.Motion.voiceSwap(theme.reduceMotion)) { detour = nil }
    }

    // MARK: ホバー展開
    func pointerEntered() {
        hoverTimer?.cancel()
        guard !dragging, !clickThrough || optionPeek, !hoverOpen else { return }
        hoverTimer = _Concurrency.Task { @MainActor [weak self] in
            try? await _Concurrency.Task.sleep(for: .seconds(PolarisTheme.Motion.hoverDelay))
            guard let self, !_Concurrency.Task.isCancelled, !self.dragging else { return }
            withAnimation(PolarisTheme.Motion.expand(self.theme.reduceMotion)) { self.hoverOpen = true }
        }
    }

    func pointerExited() {
        hoverTimer?.cancel()
        pointer = nil
        guard hoverOpen else { return }
        hoverTimer = _Concurrency.Task { @MainActor [weak self] in
            try? await _Concurrency.Task.sleep(for: .seconds(PolarisTheme.Motion.leaveDelay))
            guard let self, !_Concurrency.Task.isCancelled else { return }
            self.collapseHover()
        }
    }

    func collapseHover() {
        withAnimation(PolarisTheme.Motion.collapse(theme.reduceMotion)) {
            hoverOpen = false
            if !expanded { laterOpen = false }
        }
    }

    func togglePin() {
        if pinned {
            withAnimation(PolarisTheme.Motion.collapse(theme.reduceMotion)) {
                pinned = false; swapping = nil
                if !expanded { laterOpen = false }
            }
        } else {
            withAnimation(PolarisTheme.Motion.expand(theme.reduceMotion)) { pinned = true }
        }
    }

    func unpinAll() {
        withAnimation(PolarisTheme.Motion.collapse(theme.reduceMotion)) {
            pinned = false; hoverOpen = false; swapping = nil; editing = nil; laterOpen = false
        }
    }

    func toggleLater() {
        withAnimation(PolarisTheme.Motion.laterDisclose(theme.reduceMotion)) { laterOpen.toggle() }
    }

    // MARK: 今日はここまで
    func closeDay() {
        dayClosedDate = state.today.date
        UserDefaults.standard.set(dayClosedDate, forKey: "dayClosedDate")
        unpinAll()
    }
}
