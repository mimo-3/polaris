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
    /// 閉じた付箋はクリックを後ろへ通す。つまみだけが触れる場所になる。
    var clickThrough: Bool = Prefs.bool("clickThrough", default: true) {
        didSet {
            // スナップショットでは描き分けのために切り替えるだけなので、設定には残さない。
            if !theme.snapshot { Prefs.set(clickThrough, "clickThrough") }
            if clickThrough != oldValue { interactivityChanged() }
        }
    }
    var optionPeek = false { didSet { if optionPeek != oldValue { interactivityChanged() } } }
    /// 透過中に、つまみを押して開いている。畳んだら透過に戻る。
    var handleOpen = false { didSet { if handleOpen != oldValue { interactivityChanged() } } }
    var isKey = false
    var keyboardIndex: Int?
    var dragging = false
    var dayClosedDate: String?
    var hidden = false

    /// 付箋がクリックを受け取れる。透過していないか、⌥ を押しているか、つまみで開いている。
    var interactive: Bool { !clickThrough || optionPeek || handleOpen }

    // MARK: 表示の設定（UserDefaults に残す）
    /// 閉じているときの付箋の濃さ。開いているあいだは常に 1。
    var noteOpacity: Double = Prefs.double("noteOpacity", default: 1) { didSet { Prefs.set(noteOpacity, "noteOpacity") } }
    /// 北極星を達成したときの演出。
    var celebrates: Bool = Prefs.bool("celebrates", default: true) { didSet { Prefs.set(celebrates, "celebrates") } }
    var celebrationSound: Bool = Prefs.bool("celebrationSound", default: true) { didSet { Prefs.set(celebrationSound, "celebrationSound") } }

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
    var pointer: CGPoint? { didSet { updateHoveredRow(); updateHint() } }
    var rowFrames: [UUID: CGRect] = [:] { didSet { updateHoveredRow() } }
    var hoveredRow: UUID?
    /// ホバーで案内を出す場所。id ごとに文言と枠を持つ。描き直しを招かないよう観測から外す。
    @ObservationIgnored var hintTargets: [String: (text: String, frame: CGRect)] = [:]
    /// いま出している案内。
    var hint: NoteHint?
    @ObservationIgnored private var hintCandidate: String?
    @ObservationIgnored private var hintTask: _Concurrency.Task<Void, Never>?

    // MARK: パネルへの依頼
    @ObservationIgnored var requestKey: () -> Void = {}
    @ObservationIgnored var resignKey: () -> Void = {}
    /// クリックを受け取れるかが変わった。パネルの ignoresMouseEvents を合わせてもらう。
    @ObservationIgnored var interactivityChanged: () -> Void = {}
    @ObservationIgnored var onDayChanged: () -> Void = {}
    @ObservationIgnored var requestMorning: () -> Void = {}
    @ObservationIgnored var onStateApplied: () -> Void = {}
    /// 北極星を達成したときに、付箋の外へ演出を出す。
    @ObservationIgnored var onCelebrate: () -> Void = {}
    /// 予約の北極星が上がったとき、隠していても付箋を出す。
    @ObservationIgnored var onSurface: () -> Void = {}
    /// 予約の北極星を上げている途中。apply から何度も呼ばれても1回だけ書く。
    @ObservationIgnored var surfacing = false
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
        guard interactive else { return false }
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

    /// ポインタが止まった場所に案内があれば、少し待ってから出す。重なっていたら小さい枠を優先する。
    private func updateHint() {
        guard !theme.snapshot else { return }
        let hit = pointer.flatMap { p in
            hintTargets.filter { $0.value.frame.contains(p) }
                .min { $0.value.frame.width * $0.value.frame.height < $1.value.frame.width * $1.value.frame.height }
        }
        guard hit?.key != hintCandidate else { return }
        hintCandidate = hit?.key
        hintTask?.cancel()
        if hint != nil { hint = nil }
        guard let hit, expanded, !dragging else { return }
        hintTask = _Concurrency.Task { @MainActor [weak self] in
            try? await _Concurrency.Task.sleep(for: .seconds(PolarisTheme.Motion.hintDelay))
            guard let self, !_Concurrency.Task.isCancelled, self.expanded, self.editing == nil else { return }
            self.hint = NoteHint(text: hit.value.text, frame: hit.value.frame)
        }
    }

    func setHintTarget(_ id: String, text: String, frame: CGRect) {
        hintTargets[id] = (text, frame)
        // 出している案内の場所が動いたら、吹き出しも付いていく。
        if hintCandidate == id, hint != nil { hint = NoteHint(text: text, frame: frame) }
    }

    /// 完了などで場所ごと消えたら、ポインタが動かなくても案内を下ろす。
    func removeHintTarget(_ id: String) {
        hintTargets[id] = nil
        if hintCandidate == id { clearHint() }
    }

    func clearHint() {
        hintTask?.cancel()
        hintCandidate = nil
        if hint != nil { hint = nil }
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
        // 起動・日付の替わり目・MCP の書き込みで、もう時刻の来た予約があれば待たずに上げる（朝の支度より先に）。
        surfaceScheduledStars()
        if bannerChanged { scheduleBannerExpiry() }
        if let newBanner { announce("\(newBanner.text)。\(Copy.from(Copy.clientName(newBanner.from)))", .low) }
        if loadFailed {
            loadFailed = false
            if case .error(Copy.loadFailed) = transient { clearTransient() }
        }
        if let swapping, !next.later.contains(where: { $0.id == swapping }) { self.swapping = nil }
        if case .overflow(let id, _, _) = transient, !next.later.contains(where: { $0.id == id }) { clearTransient() }
        announceExternalChanges(from: previous, to: next, settling: firstLoad || dayChanged)
        if dayChanged {
            pinned = false; laterOpen = false; editing = nil
            onDayChanged()
        } else if firstLoad {
            onDayChanged()
        }
        onStateApplied()
    }

    /// 付箋の外（MCP）で起きた4件目と、banner に隠れたモード切り替えを声の行で知らせる。
    /// 起動直後の読み込みと日付が替わった直後（settling）は出さない。古い出来事を今のことのように出さない。
    private func announceExternalChanges(from previous: AppState, to next: AppState, settling: Bool) {
        guard !settling else { return }
        var undoShowing = false
        if case .undo = transient { undoShowing = true }
        if case .starEnded = transient { undoShowing = true }
        if let event = OverflowNotice.event(from: previous, to: next, now: Date(), settling: settling,
                                            busy: swapping != nil || undoShowing) {
            show(.overflow(taskID: event.taskID, title: event.title, client: Copy.clientName(event.source)))
            return
        }
        // モード表示が見えているなら行そのものが替わるので、知らせは要らない。
        if next.today.mode.id != previous.today.mode.id, transient == nil, detour == nil, visibleBanner != nil {
            show(.modeChanged(next.today.mode))
        }
    }

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
                if case PolarisError.northStarNotFound = error { return }
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
        case .starEnded(_, let title, let next, let achieved): announce(Copy.starEndedSpoken(title, next: next, achieved: achieved), .medium)
        case .starSurfaced(let title): announce(Copy.starSurfaced(title), .high)
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
        guard !dragging, interactive, !hoverOpen else { return }
        hoverTimer = _Concurrency.Task { @MainActor [weak self] in
            try? await _Concurrency.Task.sleep(for: .seconds(PolarisTheme.Motion.hoverDelay))
            guard let self, !_Concurrency.Task.isCancelled, !self.dragging else { return }
            withAnimation(PolarisTheme.Motion.expand(self.theme.reduceMotion)) { self.hoverOpen = true }
        }
    }

    func pointerExited() {
        hoverTimer?.cancel()
        pointer = nil
        guard expanded else { return }
        hoverTimer = _Concurrency.Task { @MainActor [weak self] in
            try? await _Concurrency.Task.sleep(for: .seconds(PolarisTheme.Motion.leaveDelay))
            guard let self, !_Concurrency.Task.isCancelled else { return }
            self.collapseIfLeft()
        }
    }

    /// カーソルが外れたら、クリックで開いたときも含めて必ず畳む。
    /// 残すのは、書いている途中・キーボードで操作中・掴んでいる最中だけ。
    func collapseIfLeft() {
        guard expanded, editing == nil, keyboardIndex == nil, !dragging else { return }
        hoverTimer?.cancel()
        // 入れ替えの途中なら、声の行の「入れ替える行を選ぶ」も一緒に下ろす。
        cancelSwap()
        unpinAll()
        if isKey { resignKey() }
    }

    func collapseHover() {
        withAnimation(PolarisTheme.Motion.collapse(theme.reduceMotion)) {
            hoverOpen = false
            if !expanded { laterOpen = false }
        }
        settleIfClosed()
    }

    /// 畳んだら、つまみで開いた印と案内を下ろす。透過中ならこれでクリックがまた後ろへ通る。
    private func settleIfClosed() {
        guard !expanded else { return }
        handleOpen = false
        clearHint()
    }

    /// つまみの上にいるあいだは、付箋から外れたことによる畳みを待たせる。
    func pointerOnHandle() {
        hoverTimer?.cancel()
    }

    func togglePin() {
        if pinned {
            withAnimation(PolarisTheme.Motion.collapse(theme.reduceMotion)) {
                pinned = false; swapping = nil
                if !expanded { laterOpen = false }
            }
            settleIfClosed()
        } else {
            withAnimation(PolarisTheme.Motion.expand(theme.reduceMotion)) { pinned = true }
        }
    }

    /// VoiceOver や自動操作から開閉する。ホバーで開いているだけでも「たたむ」で閉じられるようにする。
    func setExpanded(_ open: Bool) {
        guard !isDayClosed, interactive, open != expanded else { return }
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
        handleOpen = false
        clearHint()
    }

    /// つまみを押した。閉じていれば開き、開いていれば畳む。透過中でも開けるよう、つまみで開いた印を立てる。
    func toggleFromHandle() {
        if expanded {
            hoverTimer?.cancel()
            unpinAll()
            if isKey { resignKey() }
        } else {
            guard !isDayClosed else { return }
            handleOpen = true
            withAnimation(PolarisTheme.Motion.expand(theme.reduceMotion)) { pinned = true }
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

/// ホバーで出す案内。枠は付箋の座標（NoteCard.space）。
struct NoteHint: Equatable {
    var text: String
    var frame: CGRect
}

/// 表示の設定の読み書き。キーが無いときは既定値。
enum Prefs {
    static func double(_ key: String, default value: Double) -> Double {
        UserDefaults.standard.object(forKey: key) as? Double ?? value
    }
    static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }
    static func set(_ value: Any, _ key: String) { UserDefaults.standard.set(value, forKey: key) }
}
