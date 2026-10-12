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
            .appendingPathComponent("oss-fix-tests-\(UUID().uuidString)")
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

    @Test func testExistingHomePermissionsBecomePrivate() throws {
        let directory = try home()
        #expect(chmod(directory.path, 0o777) == 0)
        _ = try store(directory).read()
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid())
    }

    @Test func testSymlinkHomeIsRejectedWithoutTouchingTarget() throws {
        let parent = try home()
        let target = try home()
        let link = parent.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: (any Error).self) { try store(link).read() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    @Test func testSymlinkStateIsRejectedWithoutReplacingTarget() throws {
        let directory = try home()
        let subject = store(directory)
        let target = directory.appendingPathComponent("oss-fix-target.json")
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


    @Test func testDirectorySyncFailureIsReportedAfterAtomicRename() throws {
        var subject = store(try home())
        let initial = try subject.read()
        subject.syncParent = { _ in throw POSIXError(.EIO) }
        #expect(throws: POSIXError.self) { try subject.setNorthStar("rename済み") }
        let committed = try subject.read()
        #expect(committed.today.northStar == "rename済み")
        #expect(committed.revision == initial.revision + 1)
    }

    @Test func testDirectoryOpenFailureIsNotIgnored() throws {
        let missing = try home().appendingPathComponent("missing")
        #expect(throws: POSIXError.self) { try PolarisStore.syncDirectory(missing) }
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
        let target = directory.appendingPathComponent("oss-fix-target.json")
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

}
