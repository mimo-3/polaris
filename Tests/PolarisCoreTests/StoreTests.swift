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

    @Test func testOverflowingMCPAdditionRecordsTaskAndClock() throws {
        let subject = store(at: try home(), date: epoch)
        for title in ["一番", "二番", "三番"] { _ = try subject.addTask(title: title, to: .now) }

        let placement = try subject.addTask(title: "四番", to: .now, source: "mcp:claude")

        #expect(placement.overflowed)
        #expect(try subject.read().lastOverflow == OverflowEvent(
            taskID: placement.task.id, title: "四番", source: "mcp:claude", at: epoch
        ))
    }

    @Test func testOrdinaryAdditionsLeaveLastOverflowNil() throws {
        let subject = store(at: try home(), date: epoch)

        _ = try subject.addTask(title: "今やる", to: .now, source: "mcp:claude")
        _ = try subject.addTask(title: "後で", to: .later, source: "mcp:claude")

        #expect(try subject.read().lastOverflow == nil)
    }

    @Test func testOrdinaryPlacementsPreservePreviousOverflow() throws {
        let subject = store(at: try home(), date: epoch)
        for title in ["一番", "二番", "三番"] { _ = try subject.addTask(title: title, to: .now) }
        let overflow = try subject.addTask(title: "四番", to: .now, source: "mcp:claude")
        let event = try #require(try subject.read().lastOverflow)

        _ = try subject.addTask(title: "後で", to: .later)
        #expect(try subject.read().lastOverflow == event)
        let first = try #require(try subject.read().today.now.first)
        _ = try subject.completeTask(id: first.id)
        _ = try subject.moveTask(id: overflow.task.id, to: .now)

        #expect(try subject.read().lastOverflow == event)
    }

    @Test func testOverflowingMoveReplacesEventUsingCurrentClock() throws {
        let directory = try home()
        let initial = store(at: directory, date: epoch)
        for title in ["一番", "二番", "三番"] { _ = try initial.addTask(title: title, to: .now) }
        _ = try initial.addTask(title: "最初のあふれ", to: .now, source: "mcp:claude")
        let task = try initial.addTask(title: "移動する", to: .later, source: "mcp:codex").task
        let movedAt = epoch.addingTimeInterval(60)
        let subject = store(at: directory, date: movedAt)

        let placement = try subject.moveTask(id: task.id, to: .now)

        #expect(placement.overflowed)
        #expect(try subject.read().lastOverflow == OverflowEvent(
            taskID: task.id, title: task.title, source: task.source, at: movedAt
        ))
    }

    @Test func testRolloverClearsLastOverflow() throws {
        let directory = try home()
        let previous = store(at: directory, date: epoch)
        for title in ["一番", "二番", "三番", "四番"] { _ = try previous.addTask(title: title, to: .now) }
        _ = try #require(try previous.read().lastOverflow)

        let state = try store(at: directory, date: epoch.addingTimeInterval(86400)).read()

        #expect(state.lastOverflow == nil)
    }

    @Test func testDecodingStateWithoutLastOverflowKeepsSchemaVersionOne() throws {
        let json = """
        {
          "schemaVersion": 1,
          "revision": 7,
          "today": {
            "date": "2026-06-01",
            "mode": { "id": "work", "label": "仕事の日", "symbol": "briefcase", "tint": "slate", "avoidApps": [] },
            "northStar": "以前の状態",
            "now": [],
            "done": []
          },
          "later": [],
          "history": []
        }
        """

        let state = try JSONDecoder().decode(State.self, from: Data(json.utf8))

        #expect(state.lastOverflow == nil)
        #expect(state.schemaVersion == 1)
        #expect(state.revision == 7)
        #expect(state.today.northStar == "以前の状態")
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
        // 1回の書き込みを大きくして、途中の状態が見えやすくする（文字列は上限内）。
        for index in 0..<100 { _ = try subject.addTask(title: String(repeating: "星", count: 190) + "\(index)") }
        let failures = Failures()
        DispatchQueue.concurrentPerform(iterations: 4) { worker in
            do {
                if worker == 0 {
                    for index in 0..<60 { _ = try subject.setNorthStar(String(repeating: "星", count: 190) + "\(index)") }
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
                guard let first = try await iterator.next()?.get() else { return false }
                _ = try subject.setNorthStar("監視できた")
                while let next = try await iterator.next()?.get() {
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

    @Test func testWatcherKeepsRunningAfterUnreadableStateAndRecovers() async throws {
        let subject = store(at: try home(), date: epoch)
        _ = try subject.setNorthStar("最初")
        let stream = subject.changes()
        let recovered = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                guard case .success = await iterator.next() else { return false }
                let good = try Data(contentsOf: subject.stateURL)
                try Data("{broken".utf8).write(to: subject.stateURL)
                guard case .failure = await iterator.next() else { return false }
                try good.write(to: subject.stateURL)
                guard case .success(let state) = await iterator.next() else { return false }
                return state.today.northStar == "最初"
            }
            group.addTask {
                try await _Concurrency.Task.sleep(for: .seconds(8))
                return false
            }
            let result = try await group.next() ?? false
            group.cancelAll()
            return result
        }
        #expect(recovered)
    }

    @Test func testRenameKeepsIdentityPositionAndSource() throws {
        let subject = store(at: try home(), date: epoch)
        let lead = try subject.addTask(title: "本命", to: .now, source: "mcp:codex")
        _ = try subject.addTask(title: "二番", to: .now)
        let state = try subject.renameTask(id: lead.task.id, title: "  本命（改）\n ")
        #expect(state.today.now.map(\.title) == ["本命（改）", "二番"])
        #expect(state.today.now[0].id == lead.task.id)
        #expect(state.today.now[0].source == "mcp:codex")
        #expect(state.today.now[0].createdAt == lead.task.createdAt)
        #expect(throws: (any Error).self) { try subject.renameTask(id: lead.task.id, title: "  ") }
        #expect(throws: (any Error).self) { try subject.renameTask(id: UUID(), title: "無い") }
    }

    @Test func testSwapAndMorningArrangeAreSingleRevisions() throws {
        let subject = store(at: try home(), date: epoch)
        let a = try subject.addTask(title: "A", to: .now).task
        let b = try subject.addTask(title: "B", to: .now).task
        let c = try subject.addTask(title: "C", to: .now).task
        let d = try subject.addTask(title: "D", to: .now).task // later
        let before = try subject.read().revision
        let swapped = try subject.swapTasks(out: b.id, in: d.id)
        #expect(swapped.revision == before + 1)
        #expect(swapped.today.now.map(\.id) == [a.id, c.id, d.id])
        #expect(swapped.later.map(\.id) == [b.id])
        #expect(throws: (any Error).self) { try subject.swapTasks(out: b.id, in: d.id) }

        let arranged = try subject.arrangeMorning(selected: [b.id, UUID(), a.id])
        #expect(arranged.revision == before + 2)
        #expect(arranged.today.now.map(\.id) == [b.id, a.id])
        #expect(arranged.later.map(\.id) == [c.id, d.id])
        #expect(throws: (any Error).self) { try subject.arrangeMorning(selected: [a.id, b.id, c.id, d.id]) }
    }

    @Test func testTextLimitsAndControlCharacters() throws {
        let subject = store(at: try home(), date: epoch)
        #expect(throws: (any Error).self) { try subject.addTask(title: String(repeating: "あ", count: TextRules.titleMax + 1)) }
        #expect(throws: (any Error).self) { try subject.setNorthStar(String(repeating: "x", count: TextRules.northStarMax + 1)) }
        #expect(throws: (any Error).self) { try subject.nudge(text: String(repeating: "x", count: TextRules.bannerMax + 1), from: "a") }
        #expect(throws: (any Error).self) { try subject.addTask(title: "x", source: "mcp:" + String(repeating: "a", count: 65)) }
        let placed = try subject.addTask(title: "a\u{202E}b\u{0007}\nc")
        #expect(placed.task.title == "ab c")
        let banner = try subject.nudge(text: "戻ろう", from: "evil\u{202E}\nname" + String(repeating: "z", count: 100)).banner
        #expect(banner?.from.count == TextRules.clientMax)
        #expect(banner?.from.hasPrefix("evil name") == true)
    }

    @Test func testRolloverAfterClockWentBackDoesNotDuplicateHistory() throws {
        let home = try home()
        let day = 86_400.0
        _ = try store(at: home, date: epoch).addTask(title: "一日目", to: .now)
        _ = try store(at: home, date: epoch.addingTimeInterval(day)).read()
        // 時計が戻って前日の日付でもう一度 today が作られた状態を再現する。
        var state = try store(at: home, date: epoch.addingTimeInterval(day)).read()
        state.today.date = "2026-06-01"
        state.today.done = [Task(title: "戻った日", completedAt: epoch)]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: home.appendingPathComponent("state.json"))
        let rolled = try store(at: home, date: epoch.addingTimeInterval(day * 2)).read()
        #expect(rolled.history.map(\.date) == ["2026-06-01"])
        #expect(rolled.history[0].done.map(\.title) == ["戻った日"])
    }

    @Test func testResetCorruptStateMovesFileAsideOnlyWhenUnreadable() throws {
        let home = try home()
        let subject = store(at: home, date: epoch)
        _ = try subject.setNorthStar("読める")
        #expect(try subject.resetCorruptState() == nil)
        try Data("{broken".utf8).write(to: subject.stateURL)
        let backup = try #require(try subject.resetCorruptState())
        #expect(try Data(contentsOf: backup) == Data("{broken".utf8))
        #expect(try subject.read().today.northStar == "")
    }
}
