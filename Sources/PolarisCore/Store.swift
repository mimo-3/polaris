import Foundation
import Dispatch
import Darwin

/// Each operation locks a stable sidecar file, reads the latest state, and atomically replaces state.json.
public struct PolarisStore: Sendable {
    public let homeURL: URL
    public var stateURL: URL { homeURL.appendingPathComponent("state.json") }
    private let clock: @Sendable () -> Date
    private let calendar: Calendar
    private let legacyCalendar: Calendar
    private let invalidHome: Bool
    var syncParent: @Sendable (URL) throws -> Void = PolarisStore.syncDirectory
    var setBackupAttributes: @Sendable (URL) throws -> Void = {
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: $0.path)
    }
    var removeBackup: @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }

    public init(homeURL: URL? = nil, calendar: Calendar = .current, clock: @escaping @Sendable () -> Date = { Date() }) {
        let configured = ProcessInfo.processInfo.environment["POLARIS_HOME"]
        self.invalidHome = homeURL == nil && configured.map { !$0.hasPrefix("/") } == true
        self.homeURL = (homeURL ?? configured.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".polaris", isDirectory: true))
            .resolvingSymlinksInPath()
        self.legacyCalendar = calendar
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        self.calendar = gregorian; self.clock = clock
    }

    public func read() throws -> State { try transaction { _ in () }.state }

    @discardableResult public func setNorthStar(_ text: String) throws -> State {
        let text = try TextRules.checked(text, max: TextRules.northStarMax, label: "北極星")
        return try transaction { state in
            if text.isEmpty {
                if let star = state.today.star {
                    var queue = state.queuedStars
                    queue.insert(star, at: 0)
                    state.starQueue = queue
                    state.today.star = nil
                }
            } else if var star = state.today.star {
                star.text = text
                state.today.star = star
            } else if let index = state.queuedStars.firstIndex(where: { $0.text == text }) {
                // 朝の支度で昨日の分を引き継いだときなど、控えと同じ文面なら新しく作らずそれを出す。
                var queue = state.queuedStars
                var star = queue.remove(at: index)
                if star.activatedAt == nil { star.activatedAt = clock() }
                state.today.star = star
                state.starQueue = queue
            } else {
                let now = clock()
                state.today.star = NorthStar(text: text, createdAt: now, activatedAt: now)
            }
        }.state
    }
    public func addNorthStar(text: String, position: Int? = nil, dueDate: String? = nil, startsAt: Date? = nil) throws -> NorthStar {
        let text = try TextRules.checked(text, max: TextRules.northStarMax, label: "北極星")
        let dueDate = try DueDate.checked(dueDate)
        guard !text.isEmpty else { throw PolarisError.invalidInput("北極星が空です") }
        guard position == nil || position! >= 0 else { throw PolarisError.invalidInput("positionは0以上です") }
        return try transaction { state in
            guard state.queuedStars.count < TextRules.starQueueMax else {
                throw PolarisError.invalidInput("控えは\(TextRules.starQueueMax)件までです")
            }
            let star = NorthStar(text: text, createdAt: clock(), dueDate: dueDate, startsAt: startsAt)
            var queue = state.queuedStars
            queue.insert(star, at: min(position ?? queue.count, queue.count))
            state.starQueue = queue
            return star
        }.value
    }
    /// キーの省略は据え置き、二重Optionalの内側のnilは消去。
    public func updateNorthStar(id: UUID, text: String? = nil, dueDate: String?? = nil, startsAt: Date?? = nil) throws -> NorthStar {
        try transaction { state in
            let text = try text.map { try TextRules.checked($0, max: TextRules.northStarMax, label: "北極星") }
            if text?.isEmpty == true { throw PolarisError.invalidInput("北極星が空です") }
            let dueDate = try dueDate.map { try DueDate.checked($0) }
            func update(_ star: inout NorthStar) {
                if let text { star.text = text }
                if let dueDate { star.dueDate = dueDate }
                if let startsAt { star.startsAt = startsAt }
            }
            if var star = state.today.star, star.id == id {
                guard startsAt == nil else { throw PolarisError.northStarNotQueued }
                update(&star)
                state.today.star = star
                return star
            }
            var queue = state.queuedStars
            guard let index = queue.firstIndex(where: { $0.id == id }) else { throw PolarisError.northStarNotFound }
            update(&queue[index])
            state.starQueue = queue
            return queue[index]
        }.value
    }
    @discardableResult public func setNorthStarDue(id: UUID, dueDate: String?) throws -> State {
        let dueDate = try DueDate.checked(dueDate)
        return try transaction { state in
            if var star = state.today.star, star.id == id {
                star.dueDate = dueDate
                state.today.star = star
            } else {
                var queue = state.queuedStars
                guard let index = queue.firstIndex(where: { $0.id == id }) else { throw PolarisError.northStarNotFound }
                queue[index].dueDate = dueDate
                state.starQueue = queue
            }
        }.state
    }
    /// 控えの星だけに予約を付ける。今日の北極星を指定したら northStarNotQueued。
    @discardableResult public func setNorthStarStart(id: UUID, startsAt: Date?) throws -> State {
        try transaction { state in
            if state.today.star?.id == id { throw PolarisError.northStarNotQueued }
            var queue = state.queuedStars
            guard let index = queue.firstIndex(where: { $0.id == id }) else { throw PolarisError.northStarNotFound }
            queue[index].startsAt = startsAt
            state.starQueue = queue
        }.state
    }
    /// 控えのうち `startsAt <= now` のものを、startsAt が一番早い順に1つ今日の北極星にする。
    public func surfaceScheduledStar(now: Date? = nil) throws -> (state: State, surfaced: NorthStar?) {
        let now = now ?? clock()
        let result = try transaction { state -> NorthStar? in
            let due = state.queuedStars.enumerated()
                .compactMap { index, star -> (Int, NorthStar, Date)? in
                    guard let startsAt = star.startsAt, startsAt <= now else { return nil }
                    return (index, star, startsAt)
                }
                .sorted {
                    if $0.2 != $1.2 { return $0.2 < $1.2 }
                    return $0.0 < $1.0
                }
            guard let target = due.first else { return nil }
            var queue = state.queuedStars
            guard let index = queue.firstIndex(where: { $0.id == target.1.id }) else { return nil }
            var chosen = queue.remove(at: index)
            chosen.startsAt = nil
            chosen.activatedAt = now
            if let current = state.today.star { queue.insert(current, at: 0) }
            state.today.star = chosen
            state.starQueue = queue
            return chosen
        }
        return (result.state, result.value)
    }
    public func completeNorthStar(id: UUID? = nil, outcome: NorthStarOutcome = .achieved) throws -> (state: State, completed: NorthStar, next: NorthStar?) {
        let result = try transaction { state -> (NorthStar, NorthStar?) in
            if let id, state.today.star?.id != id { throw PolarisError.northStarNotFound }
            guard var completed = state.today.star else { throw PolarisError.invalidInput("北極星がありません") }
            let now = clock()
            completed.endedAt = now
            completed.outcome = outcome
            var log = state.pastStars
            log.append(completed)
            state.starLog = log
            state.today.star = nil
            var next: NorthStar?
            var queue = state.queuedStars
            // 未来に予約された星は飛ばし、予約なしまたは開始時刻を過ぎた最初の星を繰り上げる。
            if let index = queue.firstIndex(where: { $0.startsAt.map { $0 <= now } ?? true }) {
                var promoted = queue.remove(at: index)
                promoted.startsAt = nil
                if promoted.activatedAt == nil { promoted.activatedAt = now }
                state.today.star = promoted
                next = promoted
            }
            state.starQueue = queue
            return (completed, next)
        }
        return (result.state, result.value.0, result.value.1)
    }
    @discardableResult public func activateNorthStar(id: UUID) throws -> State {
        try transaction { state in
            var queue = state.queuedStars
            guard let index = queue.firstIndex(where: { $0.id == id }) else { throw PolarisError.northStarNotFound }
            var chosen = queue.remove(at: index)
            chosen.startsAt = nil
            if chosen.activatedAt == nil { chosen.activatedAt = clock() }
            if let current = state.today.star { queue.insert(current, at: 0) }
            state.today.star = chosen
            state.starQueue = queue
        }.state
    }
    @discardableResult public func moveNorthStar(id: UUID, position: Int?) throws -> State {
        guard position == nil || position! >= 0 else { throw PolarisError.invalidInput("positionは0以上です") }
        return try transaction { state in
            var queue = state.queuedStars
            guard let index = queue.firstIndex(where: { $0.id == id }) else { throw PolarisError.northStarNotFound }
            let star = queue.remove(at: index)
            queue.insert(star, at: min(position ?? queue.count, queue.count))
            state.starQueue = queue
        }.state
    }
    @discardableResult public func renameNorthStar(id: UUID, text: String) throws -> State {
        let text = try TextRules.checked(text, max: TextRules.northStarMax, label: "北極星")
        return try transaction { state in
            if var star = state.today.star, star.id == id {
                star.text = text
                state.today.star = star
            } else {
                var queue = state.queuedStars
                guard let index = queue.firstIndex(where: { $0.id == id }) else { throw PolarisError.northStarNotFound }
                queue[index].text = text
                state.starQueue = queue
            }
        }.state
    }
    @discardableResult public func removeNorthStar(id: UUID) throws -> State {
        try transaction { state in
            var queue = state.queuedStars
            guard let index = queue.firstIndex(where: { $0.id == id }) else { throw PolarisError.northStarNotFound }
            queue.remove(at: index)
            state.starQueue = queue
        }.state
    }
    @discardableResult public func reopenNorthStar(id: UUID) throws -> State {
        try transaction { state in
            guard state.queuedStars.count < TextRules.starQueueMax else {
                throw PolarisError.invalidInput("控えは\(TextRules.starQueueMax)件までです")
            }
            var log = state.pastStars
            guard let index = log.firstIndex(where: { $0.id == id }) else { throw PolarisError.northStarNotFound }
            var star = log.remove(at: index)
            star.endedAt = nil
            star.outcome = nil
            var queue = state.queuedStars
            queue.append(star)
            state.starQueue = queue
            state.starLog = log
        }.state
    }
    /// 終えたのを取り消す。ログから今日に戻し、そのとき今日にあったもの（繰り上がった分）は控えの先頭へ戻す。
    @discardableResult public func restoreNorthStar(id: UUID) throws -> State {
        try transaction { state in
            var log = state.pastStars
            guard let index = log.firstIndex(where: { $0.id == id }) else { throw PolarisError.northStarNotFound }
            var star = log.remove(at: index)
            star.endedAt = nil
            star.outcome = nil
            var queue = state.queuedStars
            if let current = state.today.star { queue.insert(current, at: 0) }
            state.today.star = star
            state.starQueue = queue
            state.starLog = log
        }.state
    }
    public func northStarLog(limit: Int = 30) throws -> [NorthStar] {
        guard (1...500).contains(limit) else { throw PolarisError.invalidInput("limitは1〜500です") }
        return Array(try read().pastStars
            .sorted { ($0.endedAt ?? .distantPast) > ($1.endedAt ?? .distantPast) }
            .prefix(limit))
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
        guard !mode.id.isEmpty, mode.id.count <= TextRules.clientMax, mode.id.unicodeScalars.count <= TextRules.clientMax else { throw PolarisError.invalidInput("モードのidが不正です") }
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
    public func addTask(title: String, to: TaskDestination = .later, position: Int? = nil, source: String = "user",
                        dueDate: String? = nil) throws -> Placement {
        let title = try checkedTitle(title)
        let dueDate = try DueDate.checked(dueDate)
        try checkActor(source)
        return try transaction { state in
            try place(Task(title: title, createdAt: clock(), source: source, dueDate: dueDate),
                      to: to, position: position, actor: source, in: &state)
        }.value
    }
    public func updateTask(id: UUID, title: String? = nil, dueDate: String?? = nil) throws -> Task {
        try transaction { state in
            let title = try title.map(checkedTitle)
            let dueDate = try dueDate.map { try DueDate.checked($0) }
            func update(_ task: inout Task) {
                if let title { task.title = title }
                if let dueDate { task.dueDate = dueDate }
            }
            if let index = state.today.now.firstIndex(where: { $0.id == id }) {
                update(&state.today.now[index]); return state.today.now[index]
            }
            if let index = state.later.firstIndex(where: { $0.id == id }) {
                update(&state.later[index]); return state.later[index]
            }
            if let index = state.today.done.firstIndex(where: { $0.id == id }) {
                guard dueDate == nil else { throw PolarisError.taskNotFound }
                update(&state.today.done[index]); return state.today.done[index]
            }
            throw PolarisError.taskNotFound
        }.value
    }
    @discardableResult public func setTaskDue(id: UUID, dueDate: String?) throws -> State {
        let dueDate = try DueDate.checked(dueDate)
        return try transaction { state in
            if let i = state.today.now.firstIndex(where: { $0.id == id }) { state.today.now[i].dueDate = dueDate }
            else if let i = state.later.firstIndex(where: { $0.id == id }) { state.later[i].dueDate = dueDate }
            else { throw PolarisError.taskNotFound }
        }.state
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
    /// 読めない state.json を state.corrupt-<日時>-<UUID>.json に退避して、新しい状態で始め直す。
    /// 読める状態なら何もしない。戻り値は退避先（退避しなかったら nil）。
    @discardableResult public func resetCorruptState() throws -> URL? {
        try withLock {
            var info = stat()
            if lstat(stateURL.path, &info) != 0 {
                if errno == ENOENT { return nil }
                throw posixError()
            }
            guard info.st_mode & S_IFMT == S_IFREG else { throw PolarisError.invalidState("通常ファイル以外は初期化できません") }
            if (try? validate(decode())) != nil { return nil }
            let stamp = ISO8601DateFormatter().string(from: clock()).replacingOccurrences(of: ":", with: "")
            let backup = homeURL.appendingPathComponent("state.corrupt-\(stamp)-\(UUID().uuidString).json")
            guard Darwin.rename(stateURL.path, backup.path) == 0 else { throw posixError() }
            // 元ファイルの日時を引き継がず、退避した順で残す。
            try? setBackupAttributes(backup)
            var fresh = State(today: Day(date: dateKey(clock())))
            fresh.revision = 1
            try write(fresh)
            let backups = ((try? FileManager.default.contentsOfDirectory(at: homeURL, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { isRotatableBackup($0) && $0 != backup }
                .sorted {
                    let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return left == right ? $0.lastPathComponent > $1.lastPathComponent : left > right
                }
            for old in backups.dropFirst(4) { try? removeBackup(old) }
            return backup
        }
    }
    private func isRotatableBackup(_ url: URL) -> Bool {
        let pattern = #"^state\.corrupt-[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z-[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\.json$"#
        guard url.lastPathComponent.range(of: pattern, options: .regularExpression) != nil else { return false }
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
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

    func observedState() throws -> (state: State, signature: [Int64]?) {
        let result = try transaction { _ in () }
        return (result.state, result.signature)
    }

    private func transaction<T>(_ body: (inout State) throws -> T) throws -> (state: State, value: T, signature: [Int64]?) {
        try withLock {
            var info = stat()
            let status = lstat(stateURL.path, &info)
            guard status == 0 || errno == ENOENT else { throw posixError() }
            let exists = status == 0
            var state = try exists ? decode() : State(today: Day(date: dateKey(clock())))
            try validate(state)
            let original = state
            if state.schemaVersion == 1 { migrateDateKeys(&state) }
            state.schemaVersion = 2
            rollover(&state, at: clock())
            let value = try body(&state)
            try validate(state)
            if !exists || state != original {
                guard state.revision < Int.max else { throw PolarisError.invalidState("revisionが上限に達しました") }
                state.revision += 1
                try write(state)
            }
            return (state, value, fileSignature())
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
        guard !invalidHome else { throw PolarisError.invalidInput("POLARIS_HOMEは絶対パスで指定してください") }
        var info = stat()
        if lstat(homeURL.path, &info) != 0 {
            guard errno == ENOENT else { throw homeError("保存先を確認できません（\(posixError())）") }
            do {
                try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            } catch { throw homeError("保存先を作成できません（\(error.localizedDescription)）") }
            guard lstat(homeURL.path, &info) == 0 else { throw homeError("保存先を確認できません（\(posixError())）") }
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            throw homeError("リンクの解決先がディレクトリではありません")
        }
        guard info.st_uid == getuid() else {
            throw homeError("保存先が現在のユーザーの所有ではありません")
        }
        guard info.st_mode & 0o022 == 0 else {
            throw homeError("保存先はほかのユーザーが書き込めます。実体ディレクトリの権限をchmod go-wで修正してください")
        }
        if info.st_mode & 0o077 != 0 {
            guard chmod(homeURL.path, 0o700) == 0 else { throw homeError("保存先の権限を変更できません（\(posixError())）") }
        }
    }
    private func homeError(_ reason: String) -> PolarisError {
        .invalidState("\(reason)。自分が所有する安全なディレクトリの実体パスをPOLARIS_HOMEに指定してください（保存先: \(homeURL.path)）")
    }

    private func decode() throws -> State {
        let fd = Darwin.open(stateURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw posixError() }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw posixError() }
        let maxBytes = 8 * 1024 * 1024
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size <= maxBytes else {
            throw PolarisError.invalidState("state.jsonは8MB以下の通常ファイルにしてください")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw posixError() }
            if count == 0 { break }
            guard data.count + count <= maxBytes else { throw PolarisError.invalidState("state.jsonは8MB以下にしてください") }
            data.append(contentsOf: buffer.prefix(count))
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(State.self, from: data)
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

    private func migrateDateKeys(_ state: inout State) {
        var unconverted = Set(state.unconvertedDateKeys ?? [])
        func convert(_ key: String) -> String {
            guard let date = parsedDateKey(key, calendar: legacyCalendar) else {
                unconverted.insert(key)
                return key
            }
            return dateKey(date)
        }
        state.today.date = convert(state.today.date)
        for index in state.history.indices { state.history[index].date = convert(state.history[index].date) }
        // dueDate は v1 の時点でグレゴリオ暦。Date 型の日時も変換不要。
        state.unconvertedDateKeys = unconverted.isEmpty ? nil : unconverted.sorted()
    }

    private func parsedDateKey(_ key: String, calendar: Calendar) -> Date? {
        guard key.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil else { return nil }
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, parts[0] > 0 else { return nil }
        // v1 に元号は保存されていないので、注入時計の元号で解釈する。
        let era = calendar.component(.era, from: clock())
        let components = DateComponents(era: era, year: parts[0], month: parts[1], day: parts[2])
        guard let date = calendar.date(from: components) else { return nil }
        let resolved = calendar.dateComponents([.era, .year, .month, .day], from: date)
        guard resolved.era == era, resolved.year == parts[0], resolved.month == parts[1], resolved.day == parts[2] else { return nil }
        return date
    }

    private func rollover(_ state: inout State, at now: Date) {
        let key = dateKey(now)
        let unconverted = Set(state.unconvertedDateKeys ?? [])
        func recognized(_ key: String) -> Bool {
            !unconverted.contains(key) && parsedDateKey(key, calendar: calendar) != nil
        }
        if recognized(state.today.date) && state.today.date < key {
            var archived = state.today
            // 時計が戻ってから進んだときは同じ日付が既にある。済は足し合わせ、ほかは新しいほうを使う。
            if let i = state.history.firstIndex(where: { $0.date == archived.date }) {
                let ids = Set(archived.done.map(\.id))
                archived.done = state.history[i].done.filter { !ids.contains($0.id) } + archived.done
                state.history.remove(at: i)
            }
            state.history.append(archived)
            state.later = state.today.now + state.later
            // 未完了の北極星は履歴に残しつつ控えの先頭へ戻す（同じ id が控えにあれば重複させない）。
            if let unfinished = state.today.star, unfinished.endedAt == nil {
                var queue = state.queuedStars
                if !queue.contains(where: { $0.id == unfinished.id }) {
                    queue.insert(unfinished, at: 0)
                    state.starQueue = queue
                }
            }
            state.today = Day(date: key, mode: state.defaultMode)
            state.lastOverflow = nil
        }
        let cutoff = dateKey(calendar.date(byAdding: .day, value: -90, to: now) ?? now)
        let unknown = state.history.filter { !recognized($0.date) }
        state.history = unknown + Array(state.history.filter { recognized($0.date) && $0.date >= cutoff }
            .sorted { $0.date < $1.date }.suffix(90))
        if let banner = state.banner, banner.expiresAt <= now { state.banner = nil }
        if var log = state.starLog, log.count > 500 {
            log.sort { ($0.endedAt ?? .distantPast) < ($1.endedAt ?? .distantPast) }
            state.starLog = Array(log.suffix(500))
        }
    }
    private func dateKey(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
    private func validate(_ state: State) throws {
        guard (1...2).contains(state.schemaVersion) else { throw PolarisError.unsupportedSchema(state.schemaVersion) }
        guard state.revision >= 0, state.today.now.count <= 3 else { throw PolarisError.invalidState("状態のrevisionまたはnow件数が不正です") }
        let active = state.today.now + state.later + state.today.done
        guard Set(active.map(\.id)).count == active.count,
              (state.today.now + state.later).allSatisfy({ $0.completedAt == nil }),
              state.today.done.allSatisfy({ $0.completedAt != nil }) else { throw PolarisError.invalidState("タスクのIDまたは完了状態が不正です") }
        if let modes = state.modes {
            guard Set(modes.map(\.id)).count == modes.count,
                  modes.contains(where: { $0.id == Mode.defaultMode.id }) else { throw PolarisError.invalidState("モード一覧が不正です") }
        }
        let queue = state.queuedStars
        let log = state.pastStars
        // 上限は追加と再開のときだけ見る。今日の北極星を控えへ戻す操作やロールオーバーで超えても読めなくしない。
        var starIDs: [UUID] = queue.map(\.id) + log.map(\.id)
        if let today = state.today.star { starIDs.append(today.id) }
        guard Set(starIDs).count == starIDs.count else { throw PolarisError.invalidState("北極星のIDが重複しています") }
        let open = (state.today.star.map { [$0] } ?? []) + queue
        guard open.allSatisfy({ $0.endedAt == nil && $0.outcome == nil }),
              log.allSatisfy({ $0.endedAt != nil && $0.outcome != nil }) else {
            throw PolarisError.invalidState("北極星の完了状態が不正です")
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
            guard !app.isEmpty, app.count <= TextRules.bundleIDMax, app.unicodeScalars.count <= TextRules.bundleIDMax else { throw PolarisError.invalidInput("アプリのIDが不正です") }
            if !apps.contains(app) { apps.append(app) }
        }
        return apps
    }
    private func checkActor(_ actor: String) throws {
        guard actor == "user" || (actor.hasPrefix("mcp:") && actor.count > 4 && actor.count <= 4 + TextRules.clientMax
                                  && actor.unicodeScalars.count <= 4 + TextRules.clientMax && TextRules.clean(actor) == actor) else { throw PolarisError.invalidInput("不正なsourceです") }
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
            guard state.later.count < TextRules.laterMax else { throw PolarisError.invalidInput("あとでは\(TextRules.laterMax)件までです") }
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
        guard data.count <= 8 * 1024 * 1024 else { throw PolarisError.invalidState("state.jsonは8MB以下にしてください") }
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
        // rename 後は保存済み。同期失敗を返すと MCP の再試行で二重登録される。
        do { try syncParent(homeURL) }
        catch {
            let message = "Polaris: state.jsonは保存済みですが親ディレクトリの同期に失敗しました: \(error)\n"
            try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
        }
    }
    static func syncDirectory(_ url: URL) throws {
        let dir = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        guard dir >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(dir) }
        guard fsync(dir) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
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
    var lastState: State?
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
            let snapshot = try store.observedState()
            let state = snapshot.state
            // 状態と同じロック内で取った署名だけを覚える。
            signature = snapshot.signature
            boundary = store.nextBoundary(for: state)
            if failing || state != lastState {
                failing = false
                lastState = state
                continuation.yield(.success(state))
            }
        } catch {
            signature = current
            if !failing { failing = true; continuation.yield(.failure(error)) }
        }
    }
}
