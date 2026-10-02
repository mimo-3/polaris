import Foundation

/// 期限（"yyyy-MM-dd" の暦日）の読み書きと、付箋・窓に出す短い表記。
enum DueDates {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static let short: Date.FormatStyle = .dateTime.month(.defaultDigits).day()

    static func date(_ string: String) -> Date? { formatter.date(from: string) }
    static func string(_ date: Date) -> String { formatter.string(from: date) }

    /// 今日から期限まで、暦日で何日あるか。期限が今日なら 0、過ぎていれば負。
    static func daysLeft(_ due: String, now: Date = Date(), calendar: Calendar = .current) -> Int? {
        guard let date = date(due) else { return nil }
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day
    }

    /// タスクの行の右に出す短い表記。「今日まで」「明日まで」「10/5まで」「2日超過」。
    static func taskLabel(_ due: String, now: Date = Date()) -> (text: String, overdue: Bool)? {
        guard let left = daysLeft(due, now: now), let date = date(due) else { return nil }
        switch left {
        case ..<0: return ("\(-left)日超過", true)
        case 0: return ("今日まで", false)
        case 1: return ("明日まで", false)
        default: return ("\(date.formatted(short))まで", false)
        }
    }

    /// 北極星の期限。「10/5まで・あと4日」「今日まで」「2日超過」。
    static func starLabel(_ due: String, now: Date = Date()) -> (text: String, overdue: Bool)? {
        guard let left = daysLeft(due, now: now), let date = date(due) else { return nil }
        switch left {
        case ..<0: return ("\(date.formatted(short))まで・\(-left)日超過", true)
        case 0: return ("今日まで", false)
        default: return ("\(date.formatted(short))まで・あと\(left)日", false)
        }
    }

    /// 予約の日時。「10/3 9:00に浮上」。
    static func surfaceLabel(_ date: Date) -> String {
        "\(date.formatted(.dateTime.month(.defaultDigits).day().hour().minute()))に今日の北極星へ"
    }

    /// タスクの期限メニューに並べる日。今日・明日・今週の金曜・来週の月曜・1週間後。
    static func presets(now: Date = Date(), calendar: Calendar = .current) -> [(label: String, value: String)] {
        let today = calendar.startOfDay(for: now)
        func add(_ days: Int) -> Date { calendar.date(byAdding: .day, value: days, to: today) ?? today }
        // weekday: 日=1 … 土=7
        let weekday = calendar.component(.weekday, from: today)
        let toFriday = (6 - weekday + 7) % 7
        let toMonday = (2 - weekday + 7) % 7 == 0 ? 7 : (2 - weekday + 7) % 7
        var items: [(String, Date)] = [("今日", today), ("明日", add(1))]
        if toFriday > 1 { items.append(("今週の金曜（\(add(toFriday).formatted(short))）", add(toFriday))) }
        items.append(("来週の月曜（\(add(toMonday).formatted(short))）", add(toMonday)))
        items.append(("1週間後（\(add(7).formatted(short))）", add(7)))
        return items.map { ($0.0, string($0.1)) }
    }

    /// 期限を決めるときの最初の候補。1週間後。
    static func defaultDue(now: Date = Date(), calendar: Calendar = .current) -> String {
        string(calendar.date(byAdding: .day, value: 7, to: now) ?? now)
    }
}
