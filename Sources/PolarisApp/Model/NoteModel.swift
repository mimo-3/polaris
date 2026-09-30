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
    @ObservationIgnored private var observation: _Concurrency.Task<Void, Never>?
    @ObservationIgnored private var bannerTimer: _Concurrency.Task<Void, Never>?

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
    /// 設定で編集したモード一覧。先頭が既定モード。
    var modes: [Mode] { state.availableModes }
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
        // あとでの行は隙間なく並ぶので、まず枠そのもので当て、外れたら少し広げて当てる。
        let hit = rowFrames.first { $0.value.contains(pointer) }?.key
            ?? rowFrames.first { $0.value.insetBy(dx: -8, dy: -4).contains(pointer) }?.key
        if hit != hoveredRow { hoveredRow = hit }
    }

    // MARK: 状態の反映
    /// 読めない間もストリームは生きていて、直れば次の読み込みで戻る。ストリーム自体が終わったら数秒おいて購読し直す。
    func startObserving() {
        guard let store, observation == nil else { return }
        observation = _Concurrency.Task { @MainActor [weak self] in
            while !_Concurrency.Task.isCancelled {
                for await result in store.changes() {
                    guard let self else { return }
                    switch result {
                    case .success(let next): self.apply(next)
                    case .failure: self.markLoadFailed()
                    }
                }
                try? await _Concurrency.Task.sleep(for: .seconds(3))
            }
        }
    }

    private func markLoadFailed() {
        guard !loadFailed else { return }
        loadFailed = true
        show(.error(Copy.loadFailed))
    }

    /// banner の期限にだけ起きて `now` を進める。期限が無いときはタイマーを持たない。
    private func scheduleBannerExpiry() {
        bannerTimer?.cancel()
        bannerTimer = nil
        now = Date()
        guard let expiry = state.banner?.expiresAt, expiry > now else { return }
        bannerTimer = _Concurrency.Task { @MainActor [weak self] in
            try? await _Concurrency.Task.sleep(for: .seconds(expiry.timeIntervalSinceNow + 0.05))
            guard let self, !_Concurrency.Task.isCancelled else { return }
            withAnimation(PolarisTheme.Motion.voiceSwap(self.theme.reduceMotion)) { self.now = Date() }
        }
    }

    func apply(_ next: AppState) {
        guard next != state else { return }
        let previous = state
        let firstLoad = state.today.date.isEmpty && !next.today.date.isEmpty
        let dayChanged = next.today.date != state.today.date && !state.today.date.isEmpty
        let leadChanged = next.today.now.first?.id != state.today.now.first?.id
        let animation: Animation? = leadChanged ? PolarisTheme.Motion.promote(theme.reduceMotion) : .easeOut(duration: 0.2)
        let newBanner = next.banner != nil && next.banner != state.banner ? next.banner : nil
        let bannerChanged = next.banner != state.banner
        withAnimation(animation) { state = next }
        if bannerChanged { scheduleBannerExpiry() }
        if let newBanner { announce("\(newBanner.text)。\(Copy.from(Copy.clientName(newBanner.from)))", .low) }
        if loadFailed {
            loadFailed = false
            if case .error(Copy.loadFailed) = transient { clearTransient() }
        }
        if let swapping, !next.later.contains(where: { $0.id == swapping }) { self.swapping = nil }
        if case .overflow(let id, _, _) = transient, !next.later.contains(where: { $0.id == id }) { clearTransient() }
        if !firstLoad && !dayChanged { announceExternalChanges(from: previous, to: next) }
        if dayChanged {
            pinned = false; laterOpen = false; editing = nil
            onDayChanged()
        } else if firstLoad {
            onDayChanged()
        }
        onStateApplied()
    }

    /// 付箋の外（MCP）で起きた4件目と、banner に隠れたモード切り替えを声の行で知らせる。
    /// 起動直後の読み込みでは呼ばない（古い出来事を今のことのように出さない）。
    private func announceExternalChanges(from previous: AppState, to next: AppState) {
        if let event = next.lastOverflow, event != previous.lastOverflow, event.source.hasPrefix("mcp:"),
           abs(Date().timeIntervalSince(event.at)) < Self.overflowFreshness, swapping == nil,
           next.later.contains(where: { $0.id == event.taskID }) {
            show(.overflow(taskID: event.taskID, title: event.title, client: Copy.clientName(event.source)))
            return
        }
        // モード表示が見えているなら行そのものが替わるので、知らせは要らない。
        if next.today.mode.id != previous.today.mode.id, transient == nil, detour == nil, visibleBanner != nil {
            show(.modeChanged(next.today.mode))
        }
    }

    /// MCP のあふれを知らせる猶予。これより古い記録は別の起動や過去の出来事とみなす。
    static let overflowFreshness: TimeInterval = 30

    /// ストア操作をメインスレッド外で行い、終わったら最新状態を反映する。
    /// `always` は成功でも失敗でも最後に1回呼ぶ（後始末用）。
    func run<T: Sendable>(_ op: @escaping @Sendable (PolarisStore) throws -> T,
                          then done: @escaping @MainActor (T) -> Void = { _ in },
                          always: @escaping @MainActor () -> Void = {}) {
        guard let store else { always(); return }
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
                always()
                done(value)
            case .failure(let error):
                always()
                // そのあいだに消されたものを操作しただけなら、保存の失敗ではない。
                if case PolarisError.taskNotFound = error { return }
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
        case .modeChanged(let mode): announce(Copy.modeChanged(mode.label), .low)
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

    /// VoiceOver や自動操作から開閉する。ホバーで開いているだけでも「たたむ」で閉じられるようにする。
    func setExpanded(_ open: Bool) {
        guard !isDayClosed, !clickThrough || optionPeek, open != expanded else { return }
        if open {
            withAnimation(PolarisTheme.Motion.expand(theme.reduceMotion)) { pinned = true }
        } else {
            hoverTimer?.cancel()
            unpinAll()
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
