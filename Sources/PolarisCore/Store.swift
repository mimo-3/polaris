import Foundation
import Dispatch
import Darwin

/// Each operation locks a stable sidecar file, reads the latest state, and atomically replaces state.json.
public struct PolarisStore: Sendable {
    public let homeURL: URL
    public var stateURL: URL { homeURL.appendingPathComponent("state.json") }
    private let clock: @Sendable () -> Date
    private let calendar: Calendar

    public init(homeURL: URL? = nil, calendar: Calendar = .current, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.homeURL = homeURL ?? ProcessInfo.processInfo.environment["POLARIS_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".polaris", isDirectory: true)
        self.calendar = calendar; self.clock = clock
    }

    public func read() throws -> State { try transaction { _ in () }.state }

    @discardableResult public func setNorthStar(_ text: String) throws -> State {
        let text = try TextRules.checked(text, max: TextRules.northStarMax, label: "北極星")
        return try transaction { $0.today.northStar = text }.state
    }
    @discardableResult public func setMode(_ id: String) throws -> State {
        try transaction { state in
            guard let mode = state.availableModes.first(where: { $0.id == id }) else { throw PolarisError.unknownMode }
            state.today.mode = mode
        }.state
    }
    /// 同じ id があれば置き換え、無ければ末尾に足す。今日のモードなら今日の分も合わせる。
    @discardableResult public func upsertMode(_ mode: Mode) throws -> State {
        var mode = mode
        mode.label = try checkedModeLabel(mode.label)
        guard !mode.id.isEmpty, mode.id.count <= TextRules.clientMax else { throw PolarisError.invalidInput("モードのidが不正です") }
        mode.avoidApps = try checkedApps(mode.avoidApps)
        return try transaction { state in
            var modes = state.availableModes
            if let i = modes.firstIndex(where: { $0.id == mode.id }) { modes[i] = mode } else { modes.append(mode) }
            state.modes = modes
            if state.today.mode.id == mode.id { state.today.mode = mode }
        }.state
    }
    /// 名前だけを変える。寄り道のアプリは書き込む時点の最新のまま残す。
    @discardableResult public func renameMode(id: String, label: String) throws -> State {
        let label = try checkedModeLabel(label)
        return try editMode(id: id) { $0.label = label }
    }
    /// 寄り道のアプリを足し引きする。同時に名前を変えられても消さないよう、最新の一覧に差分だけ当てる。
    @discardableResult public func updateAvoidApps(id: String, add: [String] = [], remove: [String] = []) throws -> State {
        let add = try checkedApps(add), remove = Set(remove.map(TextRules.clean))
        return try editMode(id: id) { mode in
            mode.avoidApps.removeAll { remove.contains($0) }
            for app in add where !mode.avoidApps.contains(app) { mode.avoidApps.append(app) }
        }
    }
    /// 既定モードと今日使っているモードは消せない。
    @discardableResult public func removeMode(id: String) throws -> State {
        guard id != Mode.defaultMode.id else { throw PolarisError.invalidInput("既定のモードは削除できません") }
        return try transaction { state in
            guard state.availableModes.contains(where: { $0.id == id }) else { throw PolarisError.unknownMode }
            guard state.today.mode.id != id else { throw PolarisError.invalidInput("今日使っているモードは削除できません") }
            state.modes = state.availableModes.filter { $0.id != id }
        }.state
    }
    @discardableResult public func setNote(_ text: String?) throws -> State {
        let text = try text.map { try TextRules.checked($0, max: TextRules.noteMax, label: "メモ") }
        return try transaction { $0.today.note = text }.state
    }
    public func addTask(title: String, to: TaskDestination = .later, position: Int? = nil, source: String = "user") throws -> Placement {
        let title = try checkedTitle(title)
        try checkActor(source)
        return try transaction { state in
            try place(Task(title: title, createdAt: clock(), source: source), to: to, position: position, actor: source, in: &state)
        }.value
    }
    @discardableResult public func completeTask(id: UUID) throws -> State {
        try transaction { state in
            var task = try remove(id, from: &state, includeDone: false)
            task.completedAt = clock(); state.today.done.append(task)
        }.state
    }
    /// `actor` は操作した側（App は "user"、MCP は "mcp:<client>"）。溢れたときの記録の出所になる。
    public func moveTask(id: UUID, to: TaskDestination, position: Int? = nil, actor: String = "user") throws -> Placement {
        try checkActor(actor)
        return try transaction { state in
            var task = try remove(id, from: &state, includeDone: true)
            task.completedAt = nil
            return try place(task, to: to, position: position, actor: actor, in: &state)
        }.value
    }
    @discardableResult public func removeTask(id: UUID) throws -> State {
        try transaction { state in _ = try remove(id, from: &state, includeDone: true) }.state
    }
    /// 名前だけを変える。id・作成日時・出所・位置はそのまま。
    @discardableResult public func renameTask(id: UUID, title: String) throws -> State {
        let title = try checkedTitle(title)
        return try transaction { state in
            if let i = state.today.now.firstIndex(where: { $0.id == id }) { state.today.now[i].title = title }
            else if let i = state.later.firstIndex(where: { $0.id == id }) { state.later[i].title = title }
            else if let i = state.today.done.firstIndex(where: { $0.id == id }) { state.today.done[i].title = title }
            else { throw PolarisError.taskNotFound }
        }.state
    }
    /// いまの `outgoing` をあとでの先頭へ、あとでの `incoming` をいまの末尾へ。1回の書き込みで行う。
    @discardableResult public func swapTasks(out outgoing: UUID, in incoming: UUID) throws -> State {
        try transaction { state in
            guard let o = state.today.now.firstIndex(where: { $0.id == outgoing }),
                  let i = state.later.firstIndex(where: { $0.id == incoming }) else { throw PolarisError.taskNotFound }
            let out = state.today.now.remove(at: o)
            let into = state.later.remove(at: i)
            state.today.now.append(into)
            state.later.insert(out, at: 0)
        }.state
    }
    /// 朝の支度の確定。選んだ順にいまへ入れ、選ばなかったいまの項目は順序を保ってあとでの先頭へ戻す。
    /// 見つからない id（そのあいだに消されたもの）は飛ばす。
    @discardableResult public func arrangeMorning(selected: [UUID]) throws -> State {
        var unique: [UUID] = []
        for id in selected where !unique.contains(id) { unique.append(id) }
        guard unique.count <= 3 else { throw PolarisError.invalidInput("いまは3件までです") }
        return try transaction { state in
            let pool = state.today.now + state.later
            let chosen = unique.compactMap { id in pool.first { $0.id == id } }
            let ids = Set(chosen.map(\.id))
            let returned = state.today.now.filter { !ids.contains($0.id) }
            state.later = returned + state.later.filter { !ids.contains($0.id) }
            state.today.now = chosen
        }.state
    }
    @discardableResult public func nudge(text: String, from: String, ttlMinutes: Double = 5) throws -> State {
        let text = try TextRules.checked(text, max: TextRules.bannerMax, label: "text")
        guard !text.isEmpty, ttlMinutes.isFinite, ttlMinutes > 0, ttlMinutes <= 1440 else {
            throw PolarisError.invalidInput("textと0超〜1440以下のttl_minutesを指定してください")
        }
        let from = TextRules.clientName(from)
        return try transaction { $0.banner = Banner(text: text, from: from, expiresAt: clock().addingTimeInterval(ttlMinutes * 60)) }.state
    }
    /// 読めない state.json を state.corrupt-<日時>.json に退避して、新しい状態で始め直す。
    /// 読める状態なら何もしない。戻り値は退避先（退避しなかったら nil）。
    @discardableResult public func resetCorruptState() throws -> URL? {
        try withLock {
            guard FileManager.default.fileExists(atPath: stateURL.path) else { return nil }
            if (try? validate(decode())) != nil { return nil }
            let stamp = ISO8601DateFormatter().string(from: clock()).replacingOccurrences(of: ":", with: "")
            let backup = homeURL.appendingPathComponent("state.corrupt-\(stamp).json")
            guard Darwin.rename(stateURL.path, backup.path) == 0 else { throw posixError() }
            var fresh = State(today: Day(date: dateKey(clock())))
            fresh.revision = 1
            try write(fresh)
            return backup
        }
    }
    public func history(days: Int = 90) throws -> [Day] {
        guard (1...90).contains(days) else { throw PolarisError.invalidInput("daysは1〜90です") }
        return Array(try read().history.suffix(days))
    }

    /// Emits the initial state and every later revision. A failed read is emitted as `.failure` and the stream
    /// stays open, so the next successful read recovers on its own. Directory watching survives atomic rename.
    /// A one-second timer only stats state.json; it reads when the file changed or a boundary (local midnight,
    /// banner expiry) has passed. Cancellation closes sources.
    public func changes() -> AsyncStream<Result<State, Error>> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            do {
                try makeHome()
                let fd = Darwin.open(homeURL.path, O_EVTONLY | O_CLOEXEC)
                guard fd >= 0 else { throw posixError() }
                let queue = DispatchQueue(label: "dev.mimo.polaris.watch")
                let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
                let timer = DispatchSource.makeTimerSource(queue: queue)
                let observer = StateObserver(store: self, continuation: continuation)
                source.setEventHandler { observer.check(force: false) }
                source.setCancelHandler { Darwin.close(fd) }
                timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(250))
                timer.setEventHandler { observer.check(force: false) }
                let lifetime = WatchLifetime(source: source, timer: timer)
                continuation.onTermination = { _ in lifetime.cancel() }
                queue.async { observer.check(force: true) }
                source.resume(); timer.resume()
            } catch {
                continuation.yield(.failure(error))
                continuation.finish()
            }
        }
    }

    /// 次に読み直すべき時刻: 翌日0時か banner の期限の早いほう。
    func nextBoundary(for state: State) -> Date {
        let now = clock()
        let midnight = calendar.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0, second: 0),
                                         matchingPolicy: .nextTime) ?? now.addingTimeInterval(3600)
        guard let expiry = state.banner?.expiresAt else { return midnight }
        return min(midnight, expiry)
    }
    func currentTime() -> Date { clock() }

    /// state.json の inode・サイズ・更新時刻。無ければ nil。
    func fileSignature() -> [Int64]? {
        var info = stat()
        guard lstat(stateURL.path, &info) == 0 else { return nil }
        return [Int64(info.st_ino), Int64(info.st_size), Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec)]
    }

    private func transaction<T>(_ body: (inout State) throws -> T) throws -> (state: State, value: T) {
        try withLock {
            let exists = FileManager.default.fileExists(atPath: stateURL.path)
            var state = try exists ? decode() : State(today: Day(date: dateKey(clock())))
            try validate(state)
            let original = state
            rollover(&state, at: clock())
            let value = try body(&state)
            try validate(state)
            if !exists || state != original {
                guard state.revision < Int.max else { throw PolarisError.invalidState("revisionが上限に達しました") }
                state.revision += 1
                try write(state)
            }
            return (state, value)
        }
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try makeHome()
        let fd = Darwin.open(homeURL.appendingPathComponent("state.lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw posixError() }
        defer { Darwin.close(fd) }
        while flock(fd, LOCK_EX) != 0 { if errno != EINTR { throw posixError() } }
        defer { _ = flock(fd, LOCK_UN) }
        removeStaleTemporaries()
        return try body()
    }

    private func makeHome() throws {
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    private func decode() throws -> State {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(State.self, from: Data(contentsOf: stateURL))
    }

    private func checkedTitle(_ title: String) throws -> String {
        let title = try TextRules.checked(title, max: TextRules.titleMax, label: "タイトル")
        guard !title.isEmpty else { throw PolarisError.invalidInput("タイトルは空にできません") }
        return title
    }

    /// 書き込み途中で落ちたときの一時ファイルを、1時間以上経っていれば消す。ロック中にだけ呼ぶ。
    private func removeStaleTemporaries() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: homeURL.path) else { return }
        let limit = Date().addingTimeInterval(-3600)
        for name in names where name.hasPrefix("polaris-backend-") && name.hasSuffix(".tmp") {
            let url = homeURL.appendingPathComponent(name)
            if let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date, modified < limit {
                try? fm.removeItem(at: url)
            }
        }
    }

    private func rollover(_ state: inout State, at now: Date) {
        let key = dateKey(now)
        if state.today.date < key {
            var archived = state.today
            // 時計が戻ってから進んだときは同じ日付が既にある。済は足し合わせ、ほかは新しいほうを使う。
            if let i = state.history.firstIndex(where: { $0.date == archived.date }) {
                let ids = Set(archived.done.map(\.id))
                archived.done = state.history[i].done.filter { !ids.contains($0.id) } + archived.done
                state.history.remove(at: i)
            }
            state.history.append(archived)
            state.later = state.today.now + state.later
            state.today = Day(date: key, mode: state.defaultMode)
            state.lastOverflow = nil
        }
        let cutoff = dateKey(calendar.date(byAdding: .day, value: -90, to: now) ?? now)
        state.history = Array(state.history.filter { $0.date >= cutoff }
            .sorted { $0.date < $1.date }.suffix(90))
        if let banner = state.banner, banner.expiresAt <= now { state.banner = nil }
    }
    private func dateKey(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
    private func validate(_ state: State) throws {
        guard state.schemaVersion == 1 else { throw PolarisError.unsupportedSchema(state.schemaVersion) }
        guard state.revision >= 0, state.today.now.count <= 3 else { throw PolarisError.invalidState("状態のrevisionまたはnow件数が不正です") }
        let active = state.today.now + state.later + state.today.done
        guard Set(active.map(\.id)).count == active.count,
              (state.today.now + state.later).allSatisfy({ $0.completedAt == nil }),
              state.today.done.allSatisfy({ $0.completedAt != nil }) else { throw PolarisError.invalidState("タスクのIDまたは完了状態が不正です") }
        if let modes = state.modes {
            guard Set(modes.map(\.id)).count == modes.count,
                  modes.contains(where: { $0.id == Mode.defaultMode.id }) else { throw PolarisError.invalidState("モード一覧が不正です") }
        }
    }
    private func editMode(id: String, _ body: (inout Mode) -> Void) throws -> State {
        try transaction { state in
            var modes = state.availableModes
            guard let i = modes.firstIndex(where: { $0.id == id }) else { throw PolarisError.unknownMode }
            body(&modes[i])
            state.modes = modes
            if state.today.mode.id == id { state.today.mode = modes[i] }
        }.state
    }
    private func checkedModeLabel(_ label: String) throws -> String {
        let label = try TextRules.checked(label, max: TextRules.modeLabelMax, label: "モード名")
        guard !label.isEmpty else { throw PolarisError.invalidInput("モード名を入れてください") }
        return label
    }
    private func checkedApps(_ raw: [String]) throws -> [String] {
        var apps: [String] = []
        for value in raw {
            let app = TextRules.clean(value)
            guard !app.isEmpty, app.count <= TextRules.bundleIDMax else { throw PolarisError.invalidInput("アプリのIDが不正です") }
            if !apps.contains(app) { apps.append(app) }
        }
        return apps
    }
    private func checkActor(_ actor: String) throws {
        guard actor == "user" || (actor.hasPrefix("mcp:") && actor.count > 4 && actor.count <= 4 + TextRules.clientMax
                                  && TextRules.clean(actor) == actor) else { throw PolarisError.invalidInput("不正なsourceです") }
    }
    private func place(_ task: Task, to: TaskDestination, position: Int?, actor: String, in state: inout State) throws -> Placement {
        guard position == nil || position! >= 0 else { throw PolarisError.invalidInput("positionは0以上です") }
        let overflow = to == .now && state.today.now.count >= 3
        if overflow {
            state.lastOverflow = OverflowEvent(taskID: task.id, title: task.title, source: actor, at: clock())
        }
        let destination: TaskDestination = overflow ? .later : to
        if destination == .now {
            state.today.now.insert(task, at: min(position ?? state.today.now.count, state.today.now.count))
        } else {
            state.later.insert(task, at: min(overflow ? state.later.count : (position ?? state.later.count), state.later.count))
        }
        return Placement(task: task, destination: destination, overflowed: overflow)
    }
    private func remove(_ id: UUID, from state: inout State, includeDone: Bool) throws -> Task {
        if let index = state.today.now.firstIndex(where: { $0.id == id }) { return state.today.now.remove(at: index) }
        if let index = state.later.firstIndex(where: { $0.id == id }) { return state.later.remove(at: index) }
        if includeDone, let index = state.today.done.firstIndex(where: { $0.id == id }) { return state.today.done.remove(at: index) }
        throw PolarisError.taskNotFound
    }
    private func write(_ state: State) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        let temp = homeURL.appendingPathComponent("polaris-backend-\(UUID().uuidString).tmp")
        let fd = Darwin.open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError() }
        defer { Darwin.close(fd); try? FileManager.default.removeItem(at: temp) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw posixError() }
                guard count > 0 else { throw POSIXError(.EIO) }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw posixError() }
        guard Darwin.rename(temp.path, stateURL.path) == 0 else { throw posixError() }
        // rename 自体を電源断から守る。
        let dir = Darwin.open(homeURL.path, O_RDONLY | O_CLOEXEC)
        if dir >= 0 { _ = fsync(dir); Darwin.close(dir) }
    }
    private func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

// Dispatch sources are only accessed through their thread-safe cancellation methods.
private final class WatchLifetime: @unchecked Sendable {
    let source: any DispatchSourceFileSystemObject
    let timer: any DispatchSourceTimer
    init(source: any DispatchSourceFileSystemObject, timer: any DispatchSourceTimer) { self.source = source; self.timer = timer }
    func cancel() { source.cancel(); timer.cancel() }
}
// check is confined to the observer's serial DispatchQueue.
private final class StateObserver: @unchecked Sendable {
    let store: PolarisStore
    let continuation: AsyncStream<Result<State, Error>>.Continuation
    var revision: Int?
    var signature: [Int64]?
    var boundary = Date.distantPast
    var failing = false
    init(store: PolarisStore, continuation: AsyncStream<Result<State, Error>>.Continuation) {
        self.store = store; self.continuation = continuation
    }
    func check(force: Bool) {
        let current = store.fileSignature()
        guard force || failing || current != signature || store.currentTime() >= boundary else { return }
        do {
            let state = try store.read()
            // read がロールオーバーで書いた分も含めて覚える。
            signature = store.fileSignature()
            boundary = store.nextBoundary(for: state)
            if failing || state.revision != revision {
                failing = false
                revision = state.revision
                continuation.yield(.success(state))
            }
        } catch {
            signature = current
            if !failing { failing = true; continuation.yield(.failure(error)) }
        }
    }
}
