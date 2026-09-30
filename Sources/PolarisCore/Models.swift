import Foundation
import CryptoKit

public struct Mode: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var symbol: String
    public var tint: String
    public var avoidApps: [String]

    public init(id: String, label: String, symbol: String, tint: String, avoidApps: [String] = []) {
        self.id = id; self.label = label; self.symbol = symbol; self.tint = tint; self.avoidApps = avoidApps
    }

    public static let defaults: [Mode] = {
        let avoid = ["com.tinyspeck.slackmacgap", "com.anthropic.claudefordesktop", "com.apple.Terminal",
                     "com.googlecode.iterm2", "com.mitchellh.ghostty", "com.todesktop.230313mzl4w4u92"]
        return [Mode(id: "work", label: "仕事の日", symbol: "briefcase", tint: "slate"),
                Mode(id: "reading", label: "読書の日", symbol: "book.closed", tint: "moss", avoidApps: avoid),
                Mode(id: "rest", label: "休む日", symbol: "cup.and.saucer", tint: "clay", avoidApps: avoid)]
    }()
    public static let defaultMode = defaults[0]
}

public struct Task: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var completedAt: Date?
    public var source: String
    public init(id: UUID = UUID(), title: String, createdAt: Date = Date(), completedAt: Date? = nil, source: String = "user") {
        self.id = id; self.title = title; self.createdAt = createdAt; self.completedAt = completedAt; self.source = source
    }
}

public enum NorthStarOutcome: String, Codable, Sendable {
    case achieved, dropped
}

public struct NorthStar: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var text: String
    public var createdAt: Date
    public var activatedAt: Date?
    public var endedAt: Date?
    public var outcome: NorthStarOutcome?

    public init(id: UUID = UUID(), text: String, createdAt: Date = Date(), activatedAt: Date? = nil,
                endedAt: Date? = nil, outcome: NorthStarOutcome? = nil) {
        self.id = id; self.text = text; self.createdAt = createdAt
        self.activatedAt = activatedAt; self.endedAt = endedAt; self.outcome = outcome
    }

    /// 旧形式の northStar 文字列から安定した id を作る。同じ date+text なら毎回同じ UUID。
    public static func stableID(date: String, text: String) -> UUID {
        let digest = SHA256.hash(data: Data("\(date)\n\(text)".utf8))
        let bytes = Array(digest.prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// 日付キー `YYYY-MM-DD` のローカル0時。移行用の createdAt / activatedAt に使う。
    public static func midnight(for dateKey: String, calendar: Calendar = .current) -> Date {
        let parts = dateKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return Date() }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) ?? Date()
    }
}

public struct Day: Codable, Sendable, Equatable {
    public var date: String
    public var mode: Mode
    /// 今日の北極星。文面の正はこのフィールド。
    public var star: NorthStar?
    public var now: [Task]
    public var done: [Task]
    public var note: String?

    /// 互換用。`star?.text ?? ""`。
    public var northStar: String { star?.text ?? "" }

    public init(date: String, mode: Mode = .defaultMode, northStar: String = "", now: [Task] = [], done: [Task] = [], note: String? = nil) {
        self.date = date; self.mode = mode; self.now = now; self.done = done; self.note = note
        if northStar.isEmpty {
            self.star = nil
        } else {
            let midnight = NorthStar.midnight(for: date)
            self.star = NorthStar(id: NorthStar.stableID(date: date, text: northStar), text: northStar,
                                  createdAt: midnight, activatedAt: midnight)
        }
    }

    enum CodingKeys: String, CodingKey {
        case date, mode, star, northStar, now, done, note
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(String.self, forKey: .date)
        mode = try c.decode(Mode.self, forKey: .mode)
        now = try c.decode([Task].self, forKey: .now)
        done = try c.decode([Task].self, forKey: .done)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        if let star = try c.decodeIfPresent(NorthStar.self, forKey: .star) {
            self.star = star
        } else {
            let text = try c.decodeIfPresent(String.self, forKey: .northStar) ?? ""
            if text.isEmpty {
                self.star = nil
            } else {
                let midnight = NorthStar.midnight(for: date)
                self.star = NorthStar(id: NorthStar.stableID(date: date, text: text), text: text,
                                      createdAt: midnight, activatedAt: midnight)
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(date, forKey: .date)
        try c.encode(mode, forKey: .mode)
        try c.encode(star, forKey: .star)
        try c.encode(northStar, forKey: .northStar)
        try c.encode(now, forKey: .now)
        try c.encode(done, forKey: .done)
        try c.encodeIfPresent(note, forKey: .note)
    }
}

public struct Banner: Codable, Sendable, Equatable {
    public var text: String
    public var from: String
    public var expiresAt: Date
    public init(text: String, from: String, expiresAt: Date) {
        self.text = text; self.from = from; self.expiresAt = expiresAt
    }
}

public struct OverflowEvent: Codable, Sendable, Equatable {
    public var taskID: UUID
    public var title: String
    public var source: String
    public var at: Date
    public init(taskID: UUID, title: String, source: String, at: Date) {
        self.taskID = taskID; self.title = title; self.source = source; self.at = at
    }
}

public struct State: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var revision: Int
    public var today: Day
    public var later: [Task]
    public var banner: Banner?
    public var history: [Day]
    public var lastOverflow: OverflowEvent?
    /// 設定で編集したモード一覧。キーが無い古い状態では nil で、`Mode.defaults` を使う。
    public var modes: [Mode]?
    /// 控えている北極星。順番つき。キーが無い古い状態では nil。
    public var starQueue: [NorthStar]?
    /// 終わった北極星。キーが無い古い状態では nil。
    public var starLog: [NorthStar]?

    public init(schemaVersion: Int = 1, revision: Int = 0, today: Day, later: [Task] = [], banner: Banner? = nil,
                history: [Day] = [], lastOverflow: OverflowEvent? = nil, modes: [Mode]? = nil,
                starQueue: [NorthStar]? = nil, starLog: [NorthStar]? = nil) {
        self.schemaVersion = schemaVersion; self.revision = revision; self.today = today
        self.later = later; self.banner = banner; self.history = history
        self.lastOverflow = lastOverflow; self.modes = modes
        self.starQueue = starQueue; self.starLog = starLog
    }
    /// 選べるモード。先頭が既定モード。
    public var availableModes: [Mode] { modes ?? Mode.defaults }
    /// 日付が替わったときに戻すモード。名前やアプリを編集していればそれを使う。
    public var defaultMode: Mode { availableModes.first { $0.id == Mode.defaultMode.id } ?? Mode.defaultMode }
    public var queuedStars: [NorthStar] { starQueue ?? [] }
    public var pastStars: [NorthStar] { starLog ?? [] }
}

/// MCP で溢れたことを付箋で知らせるかの判定。アプリの状態に依らない部分だけをここに置いてテストする。
public enum OverflowNotice {
    /// これより古い記録は別の起動や過去の出来事とみなす。
    public static let freshness: TimeInterval = 30

    /// - Parameters:
    ///   - settling: 起動直後の読み込みか日付が替わった直後。古い記録を今のことのように出さない。
    ///   - busy: 入れ替えの途中や取り消しを出しているあいだ。上書きすると操作できなくなる。
    public static func event(from previous: State, to next: State, now: Date, settling: Bool, busy: Bool) -> OverflowEvent? {
        guard !settling, !busy, let event = next.lastOverflow, event != previous.lastOverflow,
              event.source.hasPrefix("mcp:"), abs(now.timeIntervalSince(event.at)) < freshness,
              next.later.contains(where: { $0.id == event.taskID }) else { return nil }
        return event
    }
}

public enum TaskDestination: String, Codable, Sendable { case now, later }

public struct Placement: Codable, Sendable, Equatable {
    public let task: Task
    public let destination: TaskDestination
    public let overflowed: Bool
    public init(task: Task, destination: TaskDestination, overflowed: Bool) {
        self.task = task; self.destination = destination; self.overflowed = overflowed
    }
}

public enum PolarisError: Error, Sendable, LocalizedError {
    case invalidInput(String), taskNotFound, northStarNotFound, unknownMode, unsupportedSchema(Int), invalidState(String)
    public var errorDescription: String? {
        switch self {
        case .invalidInput(let message), .invalidState(let message): message
        case .taskNotFound: "タスクが見つかりません"
        case .northStarNotFound: "北極星が見つかりません"
        case .unknownMode: "モードが見つかりません"
        case .unsupportedSchema(let version): "未対応のschemaVersion: \(version)"
        }
    }
}
