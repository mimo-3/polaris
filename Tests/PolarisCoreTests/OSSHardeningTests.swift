import Testing
import Foundation
import Darwin
@testable import PolarisCore

private final class SnapshotFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func record(_ value: String) { lock.withLock { values.append(value) } }
    var all: [String] { lock.withLock { values } }
}

final class OSSHardeningTests {
    private let now = Date(timeIntervalSince1970: 1_780_272_000)
    private var homes: [URL] = []
    deinit { for home in homes { try? FileManager.default.removeItem(at: home) } }
    private func home() throws -> URL {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("polaris-test-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        homes.append(url)
        return url
    }
    private func calendar(_ identifier: Calendar.Identifier = .gregorian) -> Calendar {
        var result = Calendar(identifier: identifier)
        result.timeZone = TimeZone(secondsFromGMT: 0)!
        return result
    }
    private func store(_ directory: URL, calendar: Calendar? = nil, date: Date? = nil) -> PolarisStore {
        let date = date ?? now
        return PolarisStore(homeURL: directory, calendar: calendar ?? self.calendar(), clock: { date })
    }
    private func write(_ state: State, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: url)
    }

    @Test func testVersionOneMigratesToTwoWithoutLosingFields() throws {
        let subject = store(try home())
        let task = Task(title: "残す", createdAt: now, dueDate: "2026-06-30")
        let star = NorthStar(text: "予約", createdAt: now, dueDate: "2026-07-01", startsAt: now.addingTimeInterval(3600))
        var original = State(schemaVersion: 1, revision: 9, today: Day(date: "2026-06-01", northStar: "以前の星"), later: [task])
        original.starQueue = [star]
        try write(original, to: subject.stateURL)

        let migrated = try subject.read()
        let disk = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: subject.stateURL)) as? [String: Any])

        #expect(migrated.schemaVersion == 2)
        #expect(disk["schemaVersion"] as? Int == 2)
        #expect(migrated.later == original.later)
        #expect(migrated.today == original.today)
        #expect(migrated.queuedStars == [star])
        #expect(try subject.read() == migrated)
    }

    @Test(arguments: [Calendar.Identifier.buddhist, .japanese])
    func testLegacyCalendarKeysMigrateBeforeRollingOverExactlyOnce(identifier: Calendar.Identifier) throws {
        let legacyCalendar = calendar(identifier)
        func legacyKey(_ date: Date) -> String {
            let parts = legacyCalendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
        }
        let subject = store(try home(), calendar: legacyCalendar)
        let unfinished = Task(title: "持ち越す", createdAt: now, dueDate: "2026-06-30")
        let previous = Day(date: legacyKey(now.addingTimeInterval(-86400)), now: [unfinished], note: "昨日")
        let archived = Day(date: legacyKey(now.addingTimeInterval(-2 * 86400)), note: "一昨日")
        try write(State(schemaVersion: 1, revision: 9, today: previous, history: [archived]), to: subject.stateURL)

        let migrated = try subject.read()
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: subject.stateURL)) as? [String: Any])

        #expect(migrated.today.date == "2026-06-01")
        #expect(migrated.history.map(\.date) == ["2026-05-30", "2026-05-31"])
        #expect(migrated.history.map(\.note) == ["一昨日", "昨日"])
        #expect(migrated.later == [unfinished])
        #expect(migrated.revision == 10)
        #expect(saved["schemaVersion"] as? Int == 2)
        #expect(try subject.read() == migrated)
    }

    @Test(arguments: [Calendar.Identifier.buddhist, .japanese])
    func testLegacyTodayKeyMigratesWithoutSpuriousRollover(identifier: Calendar.Identifier) throws {
        let source = calendar(identifier)
        let year = source.component(.year, from: now)
        let subject = store(try home(), calendar: source)
        let task = Task(title: "今日のまま", createdAt: now)
        let day = Day(date: String(format: "%04d-06-01", year), now: [task], note: "残す")
        try write(State(schemaVersion: 1, today: day), to: subject.stateURL)

        let migrated = try subject.read()

        #expect(migrated.today.date == "2026-06-01")
        #expect(migrated.today.now == [task])
        #expect(migrated.today.note == "残す")
        #expect(migrated.history.isEmpty)
        #expect(migrated.schemaVersion == 2)
        #expect(try subject.read() == migrated)
    }

    @Test(arguments: ["0000-99-99", "0008-02-29"])
    func testUnparseableLegacyKeysSurviveMigrationAndLaterReads(key: String) throws {
        let subject = store(try home(), calendar: calendar(.japanese))
        let unknown = Day(date: key, note: "解釈できなくても残す")
        try write(State(schemaVersion: 1, today: Day(date: "0008-06-01"), history: [unknown]), to: subject.stateURL)

        let migrated = try subject.read()

        #expect(migrated.history == [unknown])
        #expect(migrated.schemaVersion == 2)
        #expect(try subject.read().history == [unknown])
    }

    @Test(arguments: [Calendar.Identifier.buddhist, .japanese])
    func testNonGregorianCalendarKeepsGregorianKeysAndCutoff(identifier: Calendar.Identifier) throws {
        let directory = try home()
        let subject = store(directory, calendar: calendar(identifier))
        let initial = State(today: Day(date: "2026-05-31"), history: [Day(date: "2026-03-02"), Day(date: "2026-03-03")])
        try write(initial, to: subject.stateURL)

        let state = try subject.read()

        #expect(state.today.date == "2026-06-01")
        #expect(state.history.map(\.date) == ["2026-03-03", "2026-05-31"])
        #expect(NorthStar.midnight(for: "2026-06-01", calendar: calendar(identifier)) == now)
    }

    @Test func testGregorianKeysKeepLocalTimezoneAcrossMidnight() throws {
        var local = calendar(.buddhist)
        local.timeZone = TimeZone(secondsFromGMT: 9 * 3600)!
        let subject = store(try home(), calendar: local, date: now.addingTimeInterval(-3600))
        #expect(try subject.read().today.date == "2026-06-01")
        #expect(NorthStar.midnight(for: "2026-06-01", calendar: local) == now.addingTimeInterval(-9 * 3600))
    }

    @Test func testCombiningScalarBombIsRejectedWithoutMutation() throws {
        let subject = store(try home())
        let before = try subject.read()
        let bomb = "a" + String(repeating: "\u{301}", count: 10000)
        #expect(bomb.count == 1)
        #expect(throws: PolarisError.self) { try subject.addTask(title: bomb) }
        #expect(throws: PolarisError.self) { try subject.setNorthStar(bomb) }
        #expect(throws: PolarisError.self) { try subject.nudge(text: bomb, from: "test") }
        #expect(try subject.read() == before)
        #expect(try subject.addTask(title: "か\u{3099}🙂").task.title == "か\u{3099}🙂")
    }

    @Test func testLaterLimitRejectsAdditionAndOverflowWithoutMutation() throws {
        let subject = store(try home())
        var initial = State(today: Day(date: "2026-06-01"))
        initial.later = (0..<200).map { Task(title: "later \($0)", createdAt: now) }
        initial.today.now = (0..<3).map { Task(title: "now \($0)", createdAt: now) }
        try write(initial, to: subject.stateURL)
        let before = try subject.read()

        #expect(throws: PolarisError.self) { try subject.addTask(title: "超過") }
        #expect(throws: PolarisError.self) { try subject.addTask(title: "あふれ", to: .now) }
        #expect(try subject.read() == before)
        _ = try subject.removeTask(id: initial.later[0].id)
        #expect(try subject.addTask(title: "境界内").destination == .later)
    }

    @Test func testWritableHomeIsRejectedWithoutChangingPermissions() throws {
        let directory = try home()
        #expect(chmod(directory.path, 0o777) == 0)
        #expect(throws: (any Error).self) { try store(directory).read() }
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o777)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func testSymlinkHomeResolvesAndUsesPrivateTarget() throws {
        let parent = try home()
        let target = try home()
        #expect(chmod(target.path, 0o700) == 0)
        let link = parent.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let subject = store(link)
        let task = try subject.addTask(title: "リンク経由").task
        #expect(try store(target).read().later.map(\.id) == [task.id])
        #expect(subject.homeURL == target.resolvingSymlinksInPath())
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
    }

    @Test(arguments: [0o720, 0o702, 0o777])
    func testSymlinkHomeRejectsWritableTargetWithoutChangingIt(permissions: Int) throws {
        let parent = try home()
        let target = try home()
        #expect(chmod(target.path, mode_t(permissions)) == 0)
        let link = parent.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: (any Error).self) { try store(link).read() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == permissions)
    }

    @Test func testSymlinkHomeRejectsFileTargetWithActionableMessage() throws {
        let parent = try home()
        let target = parent.appendingPathComponent("target-file")
        let bytes = Data("preserve".utf8)
        try bytes.write(to: target)
        let link = parent.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        do {
            _ = try store(link).read()
            Issue.record("通常ファイルをhomeとして受理した")
        } catch {
            #expect(String(describing: error).contains("POLARIS_HOME"))
        }
        #expect(try Data(contentsOf: target) == bytes)
    }

    @Test func testSymlinkStateIsRejectedWithoutReplacingTarget() throws {
        let directory = try home()
        let subject = store(directory)
        let target = directory.appendingPathComponent("polaris-test-target.json")
        try write(State(today: Day(date: "2026-06-01")), to: target)
        let original = try Data(contentsOf: target)
        try FileManager.default.createSymbolicLink(at: subject.stateURL, withDestinationURL: target)
        #expect(throws: (any Error).self) { try subject.read() }
        #expect(throws: (any Error).self) { try subject.addTask(title: "禁止") }
        #expect(try Data(contentsOf: target) == original)
    }

    @Test func testStateOverEightMegabytesIsInvalidStateAndPreserved() throws {
        let subject = store(try home())
        try write(State(today: Day(date: "2026-06-01")), to: subject.stateURL)
        var bytes = try Data(contentsOf: subject.stateURL)
        bytes.append(Data(repeating: 0x20, count: (8 << 20) + 1 - bytes.count))
        try bytes.write(to: subject.stateURL)
        do {
            _ = try subject.read()
            Issue.record("8MBを超えた状態が受理された")
        } catch PolarisError.invalidState { } catch { Issue.record("invalidStateではない: \(error)") }
        #expect(try Data(contentsOf: subject.stateURL) == bytes)
    }

    @Test func testCorruptBackupsAreUniqueAndOnlyFiveNewestRemain() throws {
        let subject = store(try home())
        var backups: [URL] = []
        for index in 0..<7 {
            try Data("{broken-\(index)".utf8).write(to: subject.stateURL)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(Double(-index) * 86400)], ofItemAtPath: subject.stateURL.path)
            backups.append(try #require(try subject.resetCorruptState()))
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: subject.homeURL.path)
            .filter { $0.hasPrefix("state.corrupt-") && $0.hasSuffix(".json") }
        #expect(Set(backups).count == 7)
        #expect(Set(names) == Set(backups.suffix(5).map(\.lastPathComponent)))
        for (index, backup) in backups.enumerated().suffix(5) {
            #expect(try Data(contentsOf: backup) == Data("{broken-\(index)".utf8))
        }
    }

    @Test(arguments: ["2026-06-01T+1:00", "2026-06-01T01:+1", "2026-06-01T-0:00", "2026-06-01T00:-0", "2026-06-01T０１:00", "2026-06-01T01:００", "2026-06-01T1:00", "2026-06-01T01:0"])
    func testDueTimeRejectsSignedNonASCIIAndVariableWidthDigits(value: String) {
        #expect(throws: PolarisError.self) { try DueDate.checked(value) }
    }

    @Test func testScheduledStarDefaultsToInjectedClock() throws {
        let subject = store(try home())
        let due = try subject.addNorthStar(text: "いま", startsAt: now)
        _ = try subject.addNorthStar(text: "未来", startsAt: now.addingTimeInterval(3600))
        let result = try subject.surfaceScheduledStar()
        #expect(result.surfaced?.id == due.id)
        #expect(result.surfaced?.activatedAt == now)
        #expect(try subject.surfaceScheduledStar().surfaced == nil)
    }

    @Test func testAtomicTaskUpdateValidatesEveryFieldBeforeWriting() throws {
        let subject = store(try home())
        let task = try subject.addTask(title: "元", dueDate: "2026-06-20").task
        let before = try subject.read()
        #expect(throws: PolarisError.self) { try subject.updateTask(id: task.id, title: "変更", dueDate: .some("invalid")) }
        #expect(throws: PolarisError.self) { try subject.updateTask(id: UUID(), title: "存在しない") }
        #expect(try subject.read() == before)
        let updated = try subject.updateTask(id: task.id, title: "変更", dueDate: .some(nil))
        #expect(updated.title == "変更")
        #expect(updated.dueDate == nil)
        #expect(updated.id == task.id)
        #expect(try subject.read().revision == before.revision + 1)
    }

    @Test func testAtomicNorthStarUpdateRejectsActiveScheduleWithoutRenaming() throws {
        let subject = store(try home())
        _ = try subject.setNorthStar("いまの星")
        let before = try subject.read()
        let active = try #require(before.today.star)
        #expect(throws: PolarisError.self) { try subject.updateNorthStar(id: active.id, text: "変更", startsAt: .some(now)) }
        #expect(throws: PolarisError.self) { try subject.updateNorthStar(id: active.id, text: "変更", dueDate: .some("invalid")) }
        #expect(try subject.read() == before)
    }

    @Test func testAtomicNorthStarUpdateClearsNullableFieldsInOneRevision() throws {
        let subject = store(try home())
        let star = try subject.addNorthStar(text: "予約", dueDate: "2026-06-20", startsAt: now.addingTimeInterval(3600))
        let before = try subject.read()
        let updated = try subject.updateNorthStar(id: star.id, text: "手動", dueDate: .some(nil), startsAt: .some(nil))
        #expect(updated.text == "手動")
        #expect(updated.dueDate == nil)
        #expect(updated.startsAt == nil)
        #expect(try subject.read().revision == before.revision + 1)
    }

    @Test func testWatcherObservesReplacementEvenWhenRevisionIsReused() async throws {
        let subject = store(try home())
        let original = try subject.read()
        let stream = subject.changes()
        let observed = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                guard case .success = await iterator.next() else { return false }
                var replacement = original
                replacement.today.note = "reset後の同じrevision"
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(replacement).write(to: subject.stateURL, options: .atomic)
                while let result = await iterator.next() {
                    if case .success(let state) = result, state.today.note == replacement.today.note { return true }
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


    @Test func testDirectorySyncFailureDoesNotFailCommittedMutation() throws {
        var subject = store(try home())
        let initial = try subject.read()
        subject.syncParent = { _ in throw POSIXError(.EIO) }
        _ = try subject.setNorthStar("rename済み")
        let committed = try subject.read()
        #expect(committed.today.northStar == "rename済み")
        #expect(committed.revision == initial.revision + 1)
    }

    @Test func testDirectoryOpenFailureDoesNotThrow() throws {
        var subject = store(try home())
        let initial = try subject.read()
        let missing = subject.homeURL.appendingPathComponent("missing")
        subject.syncParent = { _ in try PolarisStore.syncDirectory(missing) }
        let task = try subject.addTask(title: "open失敗後も成功").task
        let committed = try subject.read()
        #expect(committed.later.map(\.id) == [task.id])
        #expect(committed.revision == initial.revision + 1)
    }

    @Test func testSnapshotSignatureMatchesItsStateDuringConcurrentWrites() throws {
        let subject = store(try home())
        _ = try subject.read()
        let failures = SnapshotFailures()
        DispatchQueue.concurrentPerform(iterations: 3) { worker in
            do {
                for index in 0..<60 {
                    if worker == 0 {
                        _ = try subject.setNorthStar(String(repeating: "x", count: index + 1))
                    } else {
                        let snapshot = try subject.observedState()
                        let encoder = JSONEncoder()
                        encoder.dateEncodingStrategy = .iso8601
                        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        let bytes = try encoder.encode(snapshot.state)
                        if snapshot.signature?[1] != Int64(bytes.count) {
                            failures.record("revision \(snapshot.state.revision) のサイズがsignatureと不一致")
                        }
                    }
                }
            } catch { failures.record(String(describing: error)) }
        }
        #expect(failures.all.isEmpty)
    }


    @Test func testOversizedWriteKeepsPreviousBytesAndRevision() throws {
        let subject = store(try home())
        var initial = State(revision: 7, today: Day(date: "2026-06-01", note: ""))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let overhead = try encoder.encode(initial).count
        initial.today.note = String(repeating: "x", count: (8 << 20) - overhead)
        let bytes = try encoder.encode(initial)
        #expect(bytes.count == 8 << 20)
        try bytes.write(to: subject.stateURL)
        #expect(try subject.read().revision == 7)

        #expect(throws: PolarisError.self) { try subject.addTask(title: "容量を超える追加") }

        #expect(try Data(contentsOf: subject.stateURL) == bytes)
        #expect(try subject.read().revision == 7)
    }

    @Test func testResetRejectsSymlinkWithoutChangingTargetOrTimestamp() throws {
        let directory = try home()
        let subject = store(directory)
        let target = directory.appendingPathComponent("polaris-test-target.json")
        let bytes = Data("{broken".utf8)
        try bytes.write(to: target)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(at: subject.stateURL, withDestinationURL: target)

        do {
            _ = try subject.resetCorruptState()
            Issue.record("symlinkの退避が受理された")
        } catch PolarisError.invalidState { } catch { Issue.record("invalidStateではない: \(error)") }

        #expect(try Data(contentsOf: target) == bytes)
        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        #expect(attributes[.modificationDate] as? Date == now)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: subject.stateURL.path) == target.path)
    }


    @Test func testLegacyCorruptBackupNamesAreNeverRotated() throws {
        let subject = store(try home())
        let legacy = subject.homeURL.appendingPathComponent("state.corrupt-2026-01-01T000000Z.json")
        let malformedUUID = subject.homeURL.appendingPathComponent("state.corrupt-2026-01-01T000000Z-not-a-uuid.json")
        let original = Data("old backup".utf8)
        for url in [legacy, malformedUUID] {
            try original.write(to: url)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-86400)], ofItemAtPath: url.path)
        }
        var newBackups: [URL] = []
        for index in 0..<7 {
            try Data("{broken-\(index)".utf8).write(to: subject.stateURL)
            newBackups.append(try #require(try subject.resetCorruptState()))
        }
        #expect(try Data(contentsOf: legacy) == original)
        #expect(try Data(contentsOf: malformedUUID) == original)
        #expect(newBackups.filter { FileManager.default.fileExists(atPath: $0.path) }.count == 5)
    }

    @Test func testBackupAttributeFailureStillWritesFreshState() throws {
        var subject = store(try home())
        let broken = Data("{broken attributes".utf8)
        try broken.write(to: subject.stateURL)
        subject.setBackupAttributes = { _ in throw POSIXError(.EPERM) }

        let backup = try #require(try subject.resetCorruptState())

        #expect(try Data(contentsOf: backup) == broken)
        let fresh = try subject.read()
        #expect(fresh.today.date == "2026-06-01")
        #expect(fresh.revision == 1)
        #expect(fresh.schemaVersion == 2)
    }

    @Test func testBackupDeletionFailureStillCompletesReset() throws {
        var subject = store(try home())
        for index in 0..<5 {
            try Data("{old-\(index)".utf8).write(to: subject.stateURL)
            _ = try subject.resetCorruptState()
        }
        let attempted = SnapshotFailures()
        subject.removeBackup = { url in
            attempted.record(url.lastPathComponent)
            throw POSIXError(.EPERM)
        }
        let broken = Data("{new broken".utf8)
        try broken.write(to: subject.stateURL)

        let backup = try #require(try subject.resetCorruptState())

        #expect(!attempted.all.isEmpty)
        #expect(try Data(contentsOf: backup) == broken)
        #expect(try subject.read().revision == 1)
    }

    @Test(arguments: ["0000-99-99", "0008-02-29"])
    func testUnparseableLegacyTodayKeyIsPreserved(key: String) throws {
        let subject = store(try home(), calendar: calendar(.japanese))
        let unknown = Day(date: key, note: "失わない")
        try write(State(schemaVersion: 1, today: unknown), to: subject.stateURL)
        let migrated = try subject.read()
        #expect(migrated.today == unknown)
        #expect(migrated.schemaVersion == 2)
        #expect(try subject.read() == migrated)
    }

    @MainActor @Test func testQueuedRefreshBurstRunsOnceWithoutDroppingMutations() async {
        let queue = StateOperationQueue()
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        var events: [String] = []
        queue.enqueue {
            started.continuation.yield(())
            var iterator = release.stream.makeAsyncIterator()
            _ = await iterator.next()
        }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        for _ in 0..<100 { queue.enqueueRefresh { events.append("refresh") } }
        for index in 0..<3 { queue.enqueue { events.append("mutation-\(index)") } }
        let drained = queue.enqueue { }
        release.continuation.yield(())
        await drained.value
        #expect(events == ["refresh", "mutation-0", "mutation-1", "mutation-2"])
    }

    @MainActor @Test func testRefreshBurstWhileReadingSchedulesExactlyOneFollowup() async {
        let queue = StateOperationQueue()
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        var reads = 0
        queue.enqueueRefresh {
            reads += 1
            started.continuation.yield(())
            var iterator = release.stream.makeAsyncIterator()
            _ = await iterator.next()
        }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        for _ in 0..<100 { queue.enqueueRefresh { reads += 1 } }
        let drained = queue.enqueue { }
        release.continuation.yield(())
        await drained.value
        #expect(reads == 2)
        queue.enqueueRefresh { reads += 1 }
        await queue.enqueue { }.value
        #expect(reads == 3)
    }

    @Test func testVersionPrefersBundleExecutableURLToMisleadingArgumentZero() throws {
        let app = try home().appendingPathComponent("Polaris.app/Contents")
        let executable = app.appendingPathComponent("MacOS/polaris-mcp")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "3.2.1"], format: .xml, options: 0)
        try plist.write(to: app.appendingPathComponent("Info.plist"))
        #expect(PolarisVersion.version(executableURL: executable, fallbackPath: "polaris-mcp") == "3.2.1")
    }

    @Test func testVersionFallsBackToArgumentZeroOnlyWhenExecutableURLIsMissing() throws {
        let app = try home().appendingPathComponent("Polaris.app/Contents")
        let executable = app.appendingPathComponent("MacOS/polaris-mcp")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "4.5.6"], format: .xml, options: 0)
        try plist.write(to: app.appendingPathComponent("Info.plist"))
        #expect(PolarisVersion.version(executableURL: nil, fallbackPath: executable.path) == "4.5.6")
        #expect(PolarisVersion.version(executableURL: URL(fileURLWithPath: "/usr/local/bin/polaris-mcp"), fallbackPath: executable.path) == PolarisVersion.defaultVersion)
    }

}
