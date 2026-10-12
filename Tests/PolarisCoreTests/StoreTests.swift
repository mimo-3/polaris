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
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/oss-fix-tests-\(UUID().uuidString)")
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
        // MCP が作ったタスクでも、動かしたのが付箋なら出所は user。
        #expect(try subject.read().lastOverflow == OverflowEvent(
            taskID: task.id, title: task.title, source: "user", at: movedAt
        ))
    }

    @Test func testMCPMoveOfUserTaskRecordsMCPActor() throws {
        let subject = store(at: try home(), date: epoch)
        for title in ["一番", "二番", "三番"] { _ = try subject.addTask(title: title, to: .now) }
        let task = try subject.addTask(title: "自分で書いた", to: .later).task

        let placement = try subject.moveTask(id: task.id, to: .now, actor: "mcp:codex")

        #expect(placement.overflowed)
        #expect(try subject.read().lastOverflow?.source == "mcp:codex")
        #expect(throws: PolarisError.self) { try subject.moveTask(id: task.id, to: .now, actor: "codex") }
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

    @Test func testModesDefaultToBuiltInsWhenKeyIsMissing() throws {
        let subject = store(at: try home(), date: epoch)
        let state = try subject.read()
        #expect(state.modes == nil)
        #expect(state.availableModes == Mode.defaults)
        #expect(try subject.setMode("reading").today.mode.id == "reading")
    }

    @Test func testUpsertModeAddsRenamesAndCanBeSelected() throws {
        let subject = store(at: try home(), date: epoch)
        let added = try subject.upsertMode(Mode(id: "deep", label: "  集中の日 ", symbol: "circle", tint: "slate",
                                                avoidApps: ["com.example.a", "com.example.a", " com.example.b "]))
        let mode = try #require(added.availableModes.last)
        #expect(added.availableModes.count == Mode.defaults.count + 1)
        #expect(mode.label == "集中の日")
        #expect(mode.avoidApps == ["com.example.a", "com.example.b"])

        _ = try subject.setMode("deep")
        var renamed = mode; renamed.label = "深く潜る日"; renamed.avoidApps = []
        let state = try subject.upsertMode(renamed)
        #expect(state.availableModes.last?.label == "深く潜る日")
        #expect(state.today.mode == renamed)
        #expect(state.availableModes.count == Mode.defaults.count + 1)
    }

    @Test func testUpsertModeRejectsEmptyOrLongLabels() throws {
        let subject = store(at: try home(), date: epoch)
        #expect(throws: PolarisError.self) { try subject.upsertMode(Mode(id: "x", label: " ", symbol: "circle", tint: "slate")) }
        #expect(throws: PolarisError.self) {
            try subject.upsertMode(Mode(id: "x", label: String(repeating: "あ", count: TextRules.modeLabelMax + 1), symbol: "circle", tint: "slate"))
        }
        #expect(throws: PolarisError.self) { try subject.upsertMode(Mode(id: "", label: "名前", symbol: "circle", tint: "slate")) }
        #expect(try subject.read().modes == nil)
    }

    @Test func testRemoveModeProtectsDefaultAndCurrentMode() throws {
        let subject = store(at: try home(), date: epoch)
        #expect(throws: PolarisError.self) { try subject.removeMode(id: Mode.defaultMode.id) }
        _ = try subject.setMode("rest")
        #expect(throws: PolarisError.self) { try subject.removeMode(id: "rest") }
        let state = try subject.removeMode(id: "reading")
        #expect(state.availableModes.map(\.id) == ["work", "rest"])
        #expect(throws: PolarisError.self) { try subject.setMode("reading") }
        #expect(throws: PolarisError.self) { try subject.removeMode(id: "reading") }
    }

    @Test func testRolloverUsesEditedDefaultMode() throws {
        let directory = try home()
        var work = Mode.defaultMode; work.label = "しごと"; work.avoidApps = ["com.example.chat"]
        _ = try store(at: directory, date: epoch).upsertMode(work)
        _ = try store(at: directory, date: epoch).setMode("rest")

        let next = try store(at: directory, date: epoch.addingTimeInterval(86400)).read()

        #expect(next.today.mode == work)
    }

    @Test func testDecodingStateWithModesRoundTrips() throws {
        let directory = try home()
        let subject = store(at: directory, date: epoch)
        _ = try subject.upsertMode(Mode(id: "deep", label: "集中の日", symbol: "circle", tint: "moss"))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(State.self, from: Data(contentsOf: subject.stateURL))
        #expect(state.modes?.map(\.id) == ["work", "reading", "rest", "deep"])
    }

    @Test func testFieldEditsApplyToLatestMode() throws {
        let subject = store(at: try home(), date: epoch)
        _ = try subject.setMode("reading")
        _ = try subject.updateAvoidApps(id: "reading", add: ["com.example.new", " com.example.new "], remove: ["com.tinyspeck.slackmacgap"])
        let state = try subject.renameMode(id: "reading", label: " 本の日 ")
        let reading = try #require(state.availableModes.first { $0.id == "reading" })
        #expect(reading.label == "本の日")
        #expect(reading.avoidApps.last == "com.example.new")
        #expect(!reading.avoidApps.contains("com.tinyspeck.slackmacgap"))
        #expect(state.today.mode == reading)
        #expect(throws: PolarisError.self) { try subject.renameMode(id: "missing", label: "x") }
        #expect(throws: PolarisError.self) { try subject.renameMode(id: "reading", label: "  ") }
    }

    @Test func testConcurrentRenameAndAppEditsKeepBoth() throws {
        let directory = try home()
        let date = epoch
        let fixedCalendar = calendar
        let failures = Failures()
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            do {
                let writer = PolarisStore(homeURL: directory, calendar: fixedCalendar, clock: { date })
                if index.isMultiple(of: 2) {
                    _ = try writer.renameMode(id: "work", label: "名前\(index)")
                } else {
                    _ = try writer.updateAvoidApps(id: "work", add: ["com.example.\(index)"])
                }
            } catch { failures.record(error) }
        }
        let work = try #require(try store(at: directory, date: date).read().availableModes.first { $0.id == "work" })
        #expect(failures.all.isEmpty)
        #expect(work.label.hasPrefix("名前"))
        #expect(Set(work.avoidApps) == Set(stride(from: 1, to: 40, by: 2).map { "com.example.\($0)" }))
    }

    @Test func testOverflowNoticeOnlyForFreshMCPEvents() throws {
        let task = Task(title: "溢れた", source: "user")
        let before = State(today: Day(date: "2026-06-01"), later: [task])
        func after(_ source: String, at: Date) -> State {
            var state = before
            state.lastOverflow = OverflowEvent(taskID: task.id, title: task.title, source: source, at: at)
            return state
        }
        let fresh = after("mcp:claude", at: epoch)
        #expect(OverflowNotice.event(from: before, to: fresh, now: epoch.addingTimeInterval(10), settling: false, busy: false) == fresh.lastOverflow)
        // 出所が付箋、古い、起動直後や日付替わり、入れ替えや取り消しの最中、同じ記録、もう「あとで」に無い
        #expect(OverflowNotice.event(from: before, to: after("user", at: epoch), now: epoch, settling: false, busy: false) == nil)
        #expect(OverflowNotice.event(from: before, to: fresh, now: epoch.addingTimeInterval(OverflowNotice.freshness), settling: false, busy: false) == nil)
        #expect(OverflowNotice.event(from: before, to: fresh, now: epoch, settling: true, busy: false) == nil)
        #expect(OverflowNotice.event(from: before, to: fresh, now: epoch, settling: false, busy: true) == nil)
        #expect(OverflowNotice.event(from: fresh, to: fresh, now: epoch, settling: false, busy: false) == nil)
        var moved = fresh; moved.later = []
        #expect(OverflowNotice.event(from: before, to: moved, now: epoch, settling: false, busy: false) == nil)
    }

    @Test func testLegacyNorthStarJSONMigratesWithStableID() throws {
        let json = """
        {
          "schemaVersion": 1,
          "revision": 3,
          "today": {
            "date": "2026-06-01",
            "mode": { "id": "work", "label": "仕事の日", "symbol": "briefcase", "tint": "slate", "avoidApps": [] },
            "northStar": "移行する北極星",
            "now": [],
            "done": []
          },
          "later": [],
          "history": []
        }
        """
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(State.self, from: Data(json.utf8))
        let expected = NorthStar.stableID(date: "2026-06-01", text: "移行する北極星")
        #expect(state.today.northStar == "移行する北極星")
        #expect(state.today.star?.id == expected)
        #expect(state.today.star?.text == "移行する北極星")
        #expect(state.starQueue == nil)
        #expect(state.starLog == nil)
        #expect(state.queuedStars.isEmpty)
        #expect(state.pastStars.isEmpty)

        let again = try decoder.decode(State.self, from: Data(json.utf8))
        #expect(again.today.star?.id == expected)

        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let encoded = try JSONSerialization.jsonObject(with: encoder.encode(state)) as? [String: Any]
        let today = try #require(encoded?["today"] as? [String: Any])
        #expect(today["northStar"] as? String == "移行する北極星")
        #expect(today["star"] is [String: Any])
    }

    @Test func testNorthStarQueueCompletePromotesNextAndLogs() throws {
        let subject = store(at: try home(), date: epoch)
        _ = try subject.setNorthStar("今日の星")
        let queued = try subject.addNorthStar(text: "控えの星")
        let result = try subject.completeNorthStar()
        #expect(result.completed.text == "今日の星")
        #expect(result.completed.outcome == .achieved)
        #expect(result.completed.endedAt == epoch)
        #expect(result.next?.id == queued.id)
        #expect(result.state.today.star?.id == queued.id)
        #expect(result.state.today.star?.activatedAt == epoch)
        #expect(result.state.queuedStars.isEmpty)
        #expect(result.state.pastStars.map(\.text) == ["今日の星"])
    }

    @Test func testNorthStarSwitchMoveRemoveReopenAndFullQueue() throws {
        let subject = store(at: try home(), date: epoch)
        _ = try subject.setNorthStar("いま")
        let a = try subject.addNorthStar(text: "A")
        let b = try subject.addNorthStar(text: "B")
        let c = try subject.addNorthStar(text: "C")

        let switched = try subject.activateNorthStar(id: b.id)
        #expect(switched.today.star?.id == b.id)
        #expect(switched.queuedStars.map(\.text) == ["いま", "A", "C"])

        let moved = try subject.moveNorthStar(id: c.id, position: 0)
        #expect(moved.queuedStars.map(\.text) == ["C", "いま", "A"])

        let removed = try subject.removeNorthStar(id: a.id)
        #expect(removed.queuedStars.map(\.text) == ["C", "いま"])
        #expect(throws: PolarisError.self) { try subject.removeNorthStar(id: a.id) }

        let completed = try subject.completeNorthStar(outcome: .dropped)
        #expect(completed.completed.outcome == .dropped)
        #expect(completed.completed.text == "B")
        #expect(completed.next?.text == "C")
        #expect(completed.state.pastStars.map(\.text) == ["B"])

        let reopened = try subject.reopenNorthStar(id: completed.completed.id)
        #expect(reopened.pastStars.isEmpty)
        #expect(reopened.queuedStars.map(\.text) == ["いま", "B"])
        #expect(reopened.queuedStars.last?.endedAt == nil)
        #expect(reopened.queuedStars.last?.outcome == nil)

        // 控えを満杯にして追加と reopen を拒否する。
        while try subject.read().queuedStars.count < TextRules.starQueueMax {
            _ = try subject.addNorthStar(text: "埋める\(try subject.read().queuedStars.count)")
        }
        #expect(throws: PolarisError.self) { try subject.addNorthStar(text: "あふれる") }
        let finished = try subject.completeNorthStar().completed
        // complete で控えが1つ減るので、また埋めてから reopen を確かめる。
        while try subject.read().queuedStars.count < TextRules.starQueueMax {
            _ = try subject.addNorthStar(text: "再埋め\(try subject.read().queuedStars.count)")
        }
        #expect(throws: PolarisError.self) { try subject.reopenNorthStar(id: finished.id) }
        #expect(try subject.northStarLog(limit: 1).map(\.id) == [finished.id])
    }

    @Test func testRolloverReturnsUnfinishedStarToQueueFront() throws {
        let directory = try home()
        let previous = store(at: directory, date: epoch)
        _ = try previous.setNorthStar("未完了の星")
        let queued = try previous.addNorthStar(text: "控え")
        let old = try previous.read()
        let starID = try #require(old.today.star?.id)

        let state = try store(at: directory, date: epoch.addingTimeInterval(86400)).read()
        #expect(state.today.star == nil)
        #expect(state.today.northStar == "")
        #expect(state.history.first?.star?.id == starID)
        #expect(state.history.first?.northStar == "未完了の星")
        #expect(state.queuedStars.map(\.id) == [starID, queued.id])
    }

    @Test func testSettingQueuedTextActivatesItInsteadOfDuplicating() throws {
        let directory = try home()
        _ = try store(at: directory, date: epoch).setNorthStar("引き継ぐ星")
        let next = store(at: directory, date: epoch.addingTimeInterval(86400))
        let carried = try #require(try next.read().queuedStars.first)
        let state = try next.setNorthStar("引き継ぐ星")
        #expect(state.today.star?.id == carried.id)
        #expect(state.queuedStars.isEmpty)
    }

    @Test func testQueueOverLimitStaysReadable() throws {
        let subject = store(at: try home(), date: epoch)
        _ = try subject.setNorthStar("今日の星")
        for n in 0..<TextRules.starQueueMax { _ = try subject.addNorthStar(text: "控え\(n)") }
        let state = try subject.setNorthStar("")
        #expect(state.queuedStars.count == TextRules.starQueueMax + 1)
        #expect(try subject.read().queuedStars.first?.text == "今日の星")
    }

    @Test func testRestoreNorthStarUndoesCompletionInOneStep() throws {
        let subject = store(at: try home(), date: epoch)
        _ = try subject.setNorthStar("方針整理")
        let next = try subject.addNorthStar(text: "キックオフ")
        let done = try subject.completeNorthStar().completed
        let state = try subject.restoreNorthStar(id: done.id)
        #expect(state.today.star?.id == done.id)
        #expect(state.today.star?.endedAt == nil)
        #expect(state.queuedStars.map(\.id) == [next.id])
        #expect(state.pastStars.isEmpty)
        #expect(throws: PolarisError.self) { try subject.addNorthStar(text: "  ") }
    }

    @Test func testDueDateAndStartsAtDecodeCompatAndOmitWhenNil() throws {
        let json = """
        {
          "schemaVersion": 1,
          "revision": 1,
          "today": {
            "date": "2026-06-01",
            "mode": { "id": "work", "label": "仕事の日", "symbol": "briefcase", "tint": "slate", "avoidApps": [] },
            "star": {
              "id": "00000000-0000-0000-0000-000000000001",
              "text": "旧形式の星",
              "createdAt": "2026-06-01T00:00:00Z",
              "activatedAt": "2026-06-01T00:00:00Z"
            },
            "northStar": "旧形式の星",
            "now": [{
              "id": "00000000-0000-0000-0000-000000000002",
              "title": "旧形式のタスク",
              "createdAt": "2026-06-01T00:00:00Z",
              "source": "user"
            }],
            "done": []
          },
          "later": [],
          "history": []
        }
        """
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(State.self, from: Data(json.utf8))
        #expect(state.schemaVersion == 1)
        #expect(state.today.star?.dueDate == nil)
        #expect(state.today.star?.startsAt == nil)
        #expect(state.today.now.first?.dueDate == nil)

        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        let encoded = try JSONSerialization.jsonObject(with: encoder.encode(state.today.star)) as? [String: Any]
        #expect(encoded?["dueDate"] == nil)
        #expect(encoded?["startsAt"] == nil)
        let taskJSON = try JSONSerialization.jsonObject(with: encoder.encode(state.today.now.first)) as? [String: Any]
        #expect(taskJSON?["dueDate"] == nil)
    }

    @Test func testInvalidDueDateThrows() throws {
        let subject = store(at: try home(), date: epoch)
        #expect(throws: PolarisError.self) { try subject.addNorthStar(text: "星", dueDate: "2026-13-01") }
        #expect(throws: PolarisError.self) { try subject.addNorthStar(text: "星", dueDate: "2026-02-30") }
        #expect(throws: PolarisError.self) { try subject.addNorthStar(text: "星", dueDate: "06-01-2026") }
        #expect(throws: PolarisError.self) { try subject.addTask(title: "タスク", dueDate: "not-a-date") }
        do {
            _ = try subject.addNorthStar(text: "星", dueDate: "2026-02-30")
            Issue.record("expected invalidDate")
        } catch PolarisError.invalidDate {
            // ok
        }
        #expect(try DueDate.checked("2026-06-01") == "2026-06-01")
        #expect(try DueDate.checked(nil) == nil)
    }

    @Test func testDueDateAcceptsTime() throws {
        #expect(try DueDate.checked("2026-06-01T18:30") == "2026-06-01T18:30")
        #expect(try DueDate.checked("2026-06-01T00:00") == "2026-06-01T00:00")
        for bad in ["2026-06-01T24:00", "2026-06-01T9:00", "2026-06-01T18:60", "2026-06-01T", "2026-06-01T18:30:00", "2026-02-30T10:00"] {
            #expect(throws: PolarisError.self) { try DueDate.checked(bad) }
        }
        let subject = store(at: try home(), date: epoch)
        let added = try subject.addTask(title: "時刻つき", dueDate: "2026-06-01T18:30")
        #expect(added.task.dueDate == "2026-06-01T18:30")
    }

    @Test func testSetNorthStarDueAndStart() throws {
        let subject = store(at: try home(), date: epoch)
        _ = try subject.setNorthStar("今日")
        let todayID = try #require(try subject.read().today.star?.id)
        let queued = try subject.addNorthStar(text: "控え")

        let due = try subject.setNorthStarDue(id: todayID, dueDate: "2026-06-10")
        #expect(due.today.star?.dueDate == "2026-06-10")
        let cleared = try subject.setNorthStarDue(id: todayID, dueDate: nil)
        #expect(cleared.today.star?.dueDate == nil)

        let queuedDue = try subject.setNorthStarDue(id: queued.id, dueDate: "2026-06-20")
        #expect(queuedDue.queuedStars.first?.dueDate == "2026-06-20")

        let start = epoch.addingTimeInterval(3600)
        let reserved = try subject.setNorthStarStart(id: queued.id, startsAt: start)
        #expect(reserved.queuedStars.first?.startsAt == start)
        do {
            _ = try subject.setNorthStarStart(id: todayID, startsAt: start)
            Issue.record("expected northStarNotQueued")
        } catch PolarisError.northStarNotQueued {
            // ok
        }
        let manual = try subject.setNorthStarStart(id: queued.id, startsAt: nil)
        #expect(manual.queuedStars.first?.startsAt == nil)
    }

    @Test func testSurfaceScheduledStarCases() throws {
        let directory = try home()
        let subject = store(at: directory, date: epoch)
        _ = try subject.setNorthStar("いまの星")
        let early = try subject.addNorthStar(text: "早い予約", startsAt: epoch.addingTimeInterval(-60))
        let late = try subject.addNorthStar(text: "遅い予約", startsAt: epoch.addingTimeInterval(3600))
        _ = try subject.addNorthStar(text: "手動")

        let beforeNone = try subject.read()
        let none = try subject.surfaceScheduledStar(now: epoch.addingTimeInterval(-120))
        #expect(none.surfaced == nil)
        #expect(none.state.revision == beforeNone.revision)
        #expect(none.state.today.star?.text == "いまの星")

        let before = try subject.read()
        let withToday = try subject.surfaceScheduledStar(now: epoch)
        #expect(withToday.surfaced?.id == early.id)
        #expect(withToday.state.today.star?.id == early.id)
        #expect(withToday.state.today.star?.startsAt == nil)
        #expect(withToday.state.today.star?.activatedAt == epoch)
        #expect(withToday.state.queuedStars.first?.text == "いまの星")
        #expect(withToday.state.queuedStars.contains(where: { $0.id == late.id }))
        #expect(withToday.state.revision == before.revision + 1)

        let emptyHome = try home()
        let empty = store(at: emptyHome, date: epoch)
        let idle = try empty.surfaceScheduledStar(now: epoch)
        #expect(idle.surfaced == nil)
        #expect(idle.state.today.star == nil)

        let noActiveHome = try home()
        let noActive = store(at: noActiveHome, date: epoch)
        let first = try noActive.addNorthStar(text: "二番目候補", startsAt: epoch.addingTimeInterval(-10))
        let sooner = try noActive.addNorthStar(text: "一番早い", startsAt: epoch.addingTimeInterval(-30))
        _ = try noActive.addNorthStar(text: "未来", startsAt: epoch.addingTimeInterval(100))
        let surfaced = try noActive.surfaceScheduledStar(now: epoch)
        #expect(surfaced.surfaced?.id == sooner.id)
        #expect(surfaced.state.today.star?.id == sooner.id)
        #expect(surfaced.state.queuedStars.map(\.id).contains(first.id))
    }

    @Test func testCompleteNorthStarSkipsFutureReservation() throws {
        let subject = store(at: try home(), date: epoch)
        _ = try subject.setNorthStar("いま")
        let future = try subject.addNorthStar(text: "未来予約", startsAt: epoch.addingTimeInterval(86400))
        let ready = try subject.addNorthStar(text: "繰り上げ候補", startsAt: epoch.addingTimeInterval(-1))
        let result = try subject.completeNorthStar()
        #expect(result.next?.id == ready.id)
        #expect(result.state.today.star?.id == ready.id)
        #expect(result.state.today.star?.startsAt == nil)
        #expect(result.state.queuedStars.map(\.id) == [future.id])
    }

    @Test func testActivateNorthStarClearsStartsAt() throws {
        let subject = store(at: try home(), date: epoch)
        let reserved = try subject.addNorthStar(text: "予約", startsAt: epoch.addingTimeInterval(60))
        let state = try subject.activateNorthStar(id: reserved.id)
        #expect(state.today.star?.id == reserved.id)
        #expect(state.today.star?.startsAt == nil)
    }

    @Test func testSetTaskDueOnNowAndLater() throws {
        let subject = store(at: try home(), date: epoch)
        let now = try subject.addTask(title: "いま", to: .now)
        let later = try subject.addTask(title: "あとで", to: .later)
        let due = try subject.setTaskDue(id: now.task.id, dueDate: "2026-06-05")
        #expect(due.today.now.first?.dueDate == "2026-06-05")
        let laterDue = try subject.setTaskDue(id: later.task.id, dueDate: "2026-06-06")
        #expect(laterDue.later.first?.dueDate == "2026-06-06")
        let cleared = try subject.setTaskDue(id: now.task.id, dueDate: nil)
        #expect(cleared.today.now.first?.dueDate == nil)
        #expect(throws: PolarisError.self) { try subject.setTaskDue(id: UUID(), dueDate: "2026-06-01") }
    }
}
