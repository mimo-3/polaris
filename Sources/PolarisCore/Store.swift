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
        try transaction { $0.today.northStar = text }.state
    }
    @discardableResult public func setMode(_ id: String) throws -> State {
        guard let mode = Mode.defaults.first(where: { $0.id == id }) else { throw PolarisError.unknownMode }
        return try transaction { $0.today.mode = mode }.state
    }
    @discardableResult public func setNote(_ text: String?) throws -> State {
        try transaction { $0.today.note = text }.state
    }
    public func addTask(title: String, to: TaskDestination = .later, position: Int? = nil, source: String = "user") throws -> Placement {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PolarisError.invalidInput("タイトルは空にできません") }
        guard source == "user" || (source.hasPrefix("mcp:") && source.count > 4) else { throw PolarisError.invalidInput("不正なsourceです") }
        return try transaction { state in
            try place(Task(title: title, createdAt: clock(), source: source), to: to, position: position, in: &state)
        }.value
    }
    @discardableResult public func completeTask(id: UUID) throws -> State {
        try transaction { state in
            var task = try remove(id, from: &state, includeDone: false)
            task.completedAt = clock(); state.today.done.append(task)
        }.state
    }
    public func moveTask(id: UUID, to: TaskDestination, position: Int? = nil) throws -> Placement {
        try transaction { state in
            var task = try remove(id, from: &state, includeDone: true)
            task.completedAt = nil
            return try place(task, to: to, position: position, in: &state)
        }.value
    }
    @discardableResult public func removeTask(id: UUID) throws -> State {
        try transaction { state in _ = try remove(id, from: &state, includeDone: true) }.state
    }
    @discardableResult public func nudge(text: String, from: String, ttlMinutes: Double = 5) throws -> State {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ttlMinutes.isFinite, ttlMinutes > 0, ttlMinutes <= 1440 else {
            throw PolarisError.invalidInput("textと0超〜1440以下のttl_minutesを指定してください")
        }
        return try transaction { $0.banner = Banner(text: text, from: from, expiresAt: clock().addingTimeInterval(ttlMinutes * 60)) }.state
    }
    public func history(days: Int = 90) throws -> [Day] {
        guard (1...90).contains(days) else { throw PolarisError.invalidInput("daysは1〜90です") }
        return Array(try read().history.suffix(days))
    }

    /// Emits initial state and subsequent revisions. Directory watching survives atomic rename.
    /// A one-second timer also handles local midnight and banner expiration. Cancellation closes sources.
    public func changes() -> AsyncThrowingStream<State, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            do {
                try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
                let fd = Darwin.open(homeURL.path, O_EVTONLY | O_CLOEXEC)
                guard fd >= 0 else { throw posixError() }
                let queue = DispatchQueue(label: "dev.mimo.polaris.watch")
                let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
                let timer = DispatchSource.makeTimerSource(queue: queue)
                let observer = StateObserver(store: self, continuation: continuation)
                source.setEventHandler { observer.emit() }
                source.setCancelHandler { Darwin.close(fd) }
                timer.schedule(deadline: .now(), repeating: 1)
                timer.setEventHandler { observer.emit() }
                let lifetime = WatchLifetime(source: source, timer: timer)
                continuation.onTermination = { _ in lifetime.cancel() }
                source.resume(); timer.resume()
            } catch { continuation.finish(throwing: error) }
        }
    }

    private func transaction<T>(_ body: (inout State) throws -> T) throws -> (state: State, value: T) {
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        let fd = Darwin.open(homeURL.appendingPathComponent("state.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError() }
        defer { Darwin.close(fd) }
        while flock(fd, LOCK_EX) != 0 { if errno != EINTR { throw posixError() } }
        defer { _ = flock(fd, LOCK_UN) }
        let exists = FileManager.default.fileExists(atPath: stateURL.path)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var state = try exists ? decoder.decode(State.self, from: Data(contentsOf: stateURL)) : State(today: Day(date: dateKey(clock())))
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

    private func rollover(_ state: inout State, at now: Date) {
        let key = dateKey(now)
        if state.today.date < key {
            state.history.append(state.today)
            state.later = state.today.now + state.later
            state.today = Day(date: key)
        }
        let cutoff = dateKey(calendar.date(byAdding: .day, value: -90, to: now) ?? now)
        state.history = Array(state.history.filter { $0.date >= cutoff && $0.date < key }.suffix(90))
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
    }
    private func place(_ task: Task, to: TaskDestination, position: Int?, in state: inout State) throws -> Placement {
        guard position == nil || position! >= 0 else { throw PolarisError.invalidInput("positionは0以上です") }
        let overflow = to == .now && state.today.now.count >= 3
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
// emit is confined to the observer's serial DispatchQueue.
private final class StateObserver: @unchecked Sendable {
    let store: PolarisStore
    let continuation: AsyncThrowingStream<State, Error>.Continuation
    var revision: Int?
    init(store: PolarisStore, continuation: AsyncThrowingStream<State, Error>.Continuation) { self.store = store; self.continuation = continuation }
    func emit() {
        do {
            let state = try store.read()
            if state.revision != revision { revision = state.revision; continuation.yield(state) }
        } catch { continuation.finish(throwing: error) }
    }
}
