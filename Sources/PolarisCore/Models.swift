import Foundation

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

public struct Day: Codable, Sendable, Equatable {
    public var date: String
    public var mode: Mode
    public var northStar: String
    public var now: [Task]
    public var done: [Task]
    public var note: String?
    public init(date: String, mode: Mode = .defaultMode, northStar: String = "", now: [Task] = [], done: [Task] = [], note: String? = nil) {
        self.date = date; self.mode = mode; self.northStar = northStar; self.now = now; self.done = done; self.note = note
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

public struct State: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var revision: Int
    public var today: Day
    public var later: [Task]
    public var banner: Banner?
    public var history: [Day]
    public init(schemaVersion: Int = 1, revision: Int = 0, today: Day, later: [Task] = [], banner: Banner? = nil, history: [Day] = []) {
        self.schemaVersion = schemaVersion; self.revision = revision; self.today = today
        self.later = later; self.banner = banner; self.history = history
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
    case invalidInput(String), taskNotFound, unknownMode, unsupportedSchema(Int), invalidState(String)
    public var errorDescription: String? {
        switch self {
        case .invalidInput(let message), .invalidState(let message): message
        case .taskNotFound: "タスクが見つかりません"
        case .unknownMode: "モードが見つかりません"
        case .unsupportedSchema(let version): "未対応のschemaVersion: \(version)"
        }
    }
}
