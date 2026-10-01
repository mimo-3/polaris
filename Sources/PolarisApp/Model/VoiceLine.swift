import Foundation
import PolarisCore

typealias Item = PolarisCore.Task

/// 寄り道先のアプリ。
struct Detour: Equatable {
    var bundleID: String
    var appName: String
    var pid: pid_t
    var mode: Mode
}

/// 取り消し・4件目・保存失敗など、数秒だけ声の行に出るもの。
/// `modeChanged` は banner がモード表示を塞いでいるあいだにモードが替わったときだけ出す。
enum Transient: Equatable {
    case undo(taskID: UUID, index: Int, title: String, next: String?)
    case overflow(taskID: UUID, title: String, client: String?)
    case modeChanged(Mode)
    /// 北極星を終えた。付箋の1段目はもう次の北極星に替わっている。
    case starEnded(starID: UUID, title: String, next: String?, achieved: Bool)
    /// 予約していた北極星が、決めた日時になって今日の北極星に上がった。
    case starSurfaced(title: String)
    case error(String)

    var duration: TimeInterval {
        switch self {
        case .modeChanged: 4
        case .undo: 5
        case .overflow, .starEnded, .error: 6
        case .starSurfaced: 10
        }
    }
}

/// 声の行に出すもの。優先順位は 寄り道 > 取り消し・4件目 > banner > モード表示。
enum Voice: Equatable {
    case mode
    case detour(Detour)
    case transient(Transient)
    case banner(Banner)

    var id: String {
        switch self {
        case .mode: "mode"
        case .detour(let d): "detour-\(d.bundleID)"
        case .transient(let t):
            switch t {
            case .undo(let id, _, _, _): "undo-\(id)"
            case .overflow(let id, _, _): "overflow-\(id)"
            case .modeChanged(let mode): "mode-changed-\(mode.id)"
            case .starEnded(let id, _, _, _): "star-ended-\(id)"
            case .starSurfaced(let title): "star-surfaced-\(title)"
            case .error(let m): "error-\(m)"
            }
        case .banner(let b): "banner-\(b.text)-\(b.expiresAt.timeIntervalSince1970)"
        }
    }

    static func resolve(detour: Detour?, transient: Transient?, banner: Banner?, holdBanner: Bool) -> Voice {
        if let detour { return .detour(detour) }
        if let transient { return .transient(transient) }
        if let banner, !holdBanner { return .banner(banner) }
        return .mode
    }
}

/// 付箋のどの隅に置くか。
enum Corner: String, CaseIterable, Sendable {
    case topLeft, topRight, bottomRight, bottomLeft

    var isTop: Bool { self == .topLeft || self == .topRight }
    var isLeft: Bool { self == .topLeft || self == .bottomLeft }
    var label: String {
        switch self {
        case .topLeft: "左上"
        case .topRight: "右上"
        case .bottomRight: "右下"
        case .bottomLeft: "左下"
        }
    }
    /// メニューの並び（design.md 5章）。
    static let menuOrder: [Corner] = [.topLeft, .topRight, .bottomRight, .bottomLeft]
}

/// 付箋の中でテキストを編集している箇所。
enum Editing: Equatable {
    case northStar
    case rename(UUID)
    case add
}
