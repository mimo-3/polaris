import Testing
import Foundation
import PolarisCore

private final class Failures: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    func record(_ error: Error) { lock.withLock { messages.append(String(describing: error)) } }
    var all: [String] { lock.withLock { messages } }
}

final class StoreTests {
    private let epoch = Date(timeIntervalSince1970: 1_780_272_000) // 2026-06-01 UTC
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(secondsFromGMT: 0)!
        return result
    }
    private var homes: [URL] = []
    deinit { for url in homes { try? FileManager.default.removeItem(at: url) } }
    private func home() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("polaris-backend-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        homes.append(url)
        return url
    }
    private func store(at home: URL, date: Date) -> PolarisStore {
        PolarisStore(homeURL: home, calendar: calendar, clock: { date })
    }

    @Test func testFourthNowTaskGoesToLaterWithoutReplacingFocus() throws {
        let subject = store(at: try home(), date: epoch)
        let first = try subject.addTask(title: "本命", to: .now)
        _ = try subject.addTask(title: "二番", to: .now)
        _ = try subject.addTask(title: "三番", to: .now)
        let overflow = try subject.addTask(title: "四番", to: .now, position: 0)
        let state = try subject.read()
        #expect(state.today.now.map(\.title) == ["本命", "二番", "三番"])
        #expect(state.today.now.first?.id == first.task.id)
        #expect(state.later.map(\.id) == [overflow.task.id])
        #expect(overflow.overflowed)
        #expect(overflow.destination == .later)
    }

    @Test func testCompletingFocusPromotesNextAndPreservesCompletionTime() throws {
        let subject = store(at: try home(), date: epoch)
        let first = try subject.addTask(title: "本命", to: .now)
        let second = try subject.addTask(title: "次", to: .now)
        let state = try subject.completeTask(id: first.task.id)
        #expect(state.today.now.map(\.id) == [second.task.id])
        #expect(state.today.done.first?.id == first.task.id)
        #expect(state.today.done.first?.completedAt == epoch)
    }

    @Test func testDefaultAdditionIsLaterAndReorderingDoesNotDuplicateTask() throws {
        let subject = store(at: try home(), date: epoch)
        let task = try subject.addTask(title: "後で")
        #expect(task.destination == .later)
        _ = try subject.moveTask(id: task.task.id, to: .now)
        _ = try subject.moveTask(id: task.task.id, to: .now, position: 0)
        let state = try subject.read()
        #expect(state.today.now.map(\.id) == [task.task.id])
        #expect(state.later.isEmpty)
    }

    @Test func testFailedMutationDoesNotChangePersistedStateOrRevision() throws {
        let subject = store(at: try home(), date: epoch)
        let task = try subject.addTask(title: "保持")
        let before = try subject.read()
        #expect(throws: (any Error).self) { try subject.moveTask(id: task.task.id, to: .now, position: -1) }
        #expect(throws: (any Error).self) { try subject.addTask(title: " \n ") }
        #expect(throws: (any Error).self) { try subject.completeTask(id: UUID()) }
        #expect(throws: (any Error).self) { try subject.setMode("missing") }
        #expect(try subject.read() == before)
    }

    @Test func testRolloverArchivesDayAndPrependsUnfinishedTasksInOrder() throws {
        let directory = try home()
        let previous = store(at: directory, date: epoch)
        _ = try previous.setMode("reading")
        _ = try previous.setNorthStar("読み切る")
        _ = try previous.addTask(title: "後で")
        _ = try previous.addTask(title: "一番", to: .now)
        _ = try previous.addTask(title: "二番", to: .now)
        let finished = try previous.addTask(title: "完了", to: .now)
        _ = try previous.completeTask(id: finished.task.id)
        let old = try previous.read()
        let subject = store(at: directory, date: epoch.addingTimeInterval(86400))
        let state = try subject.read()
        #expect(state.history == [old.today])
        #expect(state.later.map(\.title) == ["一番", "二番", "後で"])
        #expect(state.today.mode == .defaultMode)
        #expect(state.today.northStar == "")
        #expect(state.today.now.isEmpty)
        #expect(state.today.done.isEmpty)
        #expect(state.revision == old.revision + 1)
        #expect(try subject.read() == state)
    }

    @Test func testHistoryRetainsOnlyPreviousNinetyCalendarDays() throws {
        let directory = try home()
        for day in 0...100 {
            _ = try store(at: directory, date: epoch.addingTimeInterval(Double(day) * 86400)).read()
        }
        let subject = store(at: directory, date: epoch.addingTimeInterval(100 * 86400))
        let history = try subject.history()
        #expect(history.count == 90)
        #expect(try subject.history(days: 2) == Array(history.suffix(2)))
        #expect(throws: (any Error).self) { try subject.history(days: 0) }
        let muchLater = store(at: directory, date: epoch.addingTimeInterval(300 * 86400))
        #expect(try muchLater.read().history.isEmpty)
    }

    @Test func testBannerReplacesPreviousMessageAndExpiresAtBoundary() throws {
        let directory = try home()
        let subject = store(at: directory, date: epoch)
        _ = try subject.nudge(text: "最初", from: "one")
        let state = try subject.nudge(text: "次", from: "two", ttlMinutes: 1)
        #expect(state.banner?.text == "次")
        #expect(state.banner?.from == "two")
        #expect(try store(at: directory, date: epoch.addingTimeInterval(59)).read().banner != nil)
        #expect(try store(at: directory, date: epoch.addingTimeInterval(60)).read().banner == nil)
    }

    @Test func testConcurrentWritersNeverLoseRevisionOrTasks() throws {
        let directory = try home()
        let date = epoch
        let fixedCalendar = calendar
        let initial = try store(at: directory, date: date).read()
        let failures = Failures()
        DispatchQueue.concurrentPerform(iterations: 80) { index in
            do {
                let writer = PolarisStore(homeURL: directory, calendar: fixedCalendar, clock: { date })
                _ = try writer.addTask(title: "task \(index)")
            } catch { failures.record(error) }
        }
        let state = try store(at: directory, date: date).read()
        #expect(failures.all.isEmpty)
        #expect(state.revision == initial.revision + 80)
        #expect(Set(state.later.map(\.title)).count == 80)
    }

    @Test func testUncoordinatedReadersAlwaysObserveCompleteJSONDuringWrites() throws {
        let subject = store(at: try home(), date: epoch)
        _ = try subject.read()
        let failures = Failures()
        DispatchQueue.concurrentPerform(iterations: 4) { worker in
            do {
                if worker == 0 {
                    for index in 0..<60 { _ = try subject.setNorthStar(String(repeating: "星", count: 2000) + "\(index)") }
                } else {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    for _ in 0..<200 {
                        _ = try decoder.decode(State.self, from: Data(contentsOf: subject.stateURL))
                    }
                }
            } catch { failures.record(error) }
        }
        #expect(failures.all.isEmpty)
    }

    @Test func testCorruptJSONAndUnknownSchemaAreNotOverwritten() throws {
        let subject = store(at: try home(), date: epoch)
        let original = try subject.read()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var unsupported = original
        unsupported.schemaVersion = 999
        let inputs = [Data("{broken".utf8), try encoder.encode(unsupported)]
        for bytes in inputs {
            try bytes.write(to: subject.stateURL)
            #expect(throws: (any Error).self) { try subject.read() }
            #expect(throws: (any Error).self) { try subject.addTask(title: "上書きしない") }
            #expect(try Data(contentsOf: subject.stateURL) == bytes)
        }
    }

    @Test func testWatcherEmitsInitialStateAndExternalAtomicReplacement() async throws {
        let subject = store(at: try home(), date: epoch)
        let stream = subject.changes()
        let observed = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                guard let first = try await iterator.next() else { return false }
                _ = try subject.setNorthStar("監視できた")
                while let next = try await iterator.next() {
                    if next.revision > first.revision { return next.today.northStar == "監視できた" }
                }
                return false
            }
            group.addTask {
                try await _Concurrency.Task.sleep(for: .seconds(5))
                return false
            }
            let result = try await group.next() ?? false
            group.cancelAll()
            return result
        }
        #expect(observed)
    }
}
