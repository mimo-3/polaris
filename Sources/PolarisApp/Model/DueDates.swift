import Foundation

/// 期限の読み書きと、付箋・窓に出す短い表記。
/// 期限は "yyyy-MM-dd"（その日の終わりまで）か "yyyy-MM-ddTHH:mm"（その時刻まで）。どちらもローカル時刻。
enum DueDates {
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = format
        return f
    }
    private static let dayFormatter = formatter("yyyy-MM-dd")
    private static let timeFormatter = formatter("yyyy-MM-dd'T'HH:mm")
    private static let short: Date.FormatStyle = .dateTime.month(.defaultDigits).day()
    private static let clock: Date.FormatStyle = .dateTime.hour().minute()

    static func hasTime(_ string: String) -> Bool { string.contains("T") }

    /// 期限の文字列が指す日時。日付だけなら、その日の 0:00。
    static func date(_ string: String) -> Date? {
        hasTime(string) ? timeFormatter.date(from: string) : dayFormatter.date(from: string)
    }
    static func string(_ date: Date) -> String { dayFormatter.string(from: date) }
    static func string(dateTime date: Date) -> String { timeFormatter.string(from: date) }

    /// 締め切りの瞬間。日付だけなら翌日の 0:00（その日いっぱい）。
    static func deadline(_ string: String, calendar: Calendar = .current) -> Date? {
        guard let date = date(string) else { return nil }
        return hasTime(string) ? date : calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
    }

    /// 日時の入力欄に出す値。日付だけの期限は、その日の 23:59 として見せる。
    static func pickerDate(_ string: String, calendar: Calendar = .current) -> Date? {
        guard let date = date(string) else { return nil }
        return hasTime(string) ? date : calendar.date(bySettingHour: 23, minute: 59, second: 0, of: date)
    }

    /// 残りの短い表記。「あと45分」「あと3時間」「あと4日」、過ぎていれば「2時間超過」。
    static func remaining(_ due: String, now: Date = Date()) -> (text: String, overdue: Bool)? {
        guard let deadline = deadline(due) else { return nil }
        let seconds = deadline.timeIntervalSince(now)
        let span = abs(seconds)
        let amount: String
        if span < 3600 { amount = "\(max(Int(span / 60), 1))分" }
        else if span < 86400 { amount = "\(Int(span / 3600))時間" }
        else { amount = "\(Int(span / 86400))日" }
        return seconds >= 0 ? ("あと\(amount)", false) : ("\(amount)超過", true)
    }

    /// 期限の日時そのもの。「10/5」「10/5 18:00」。
    static func whenText(_ due: String) -> String? {
        guard let date = date(due) else { return nil }
        return hasTime(due) ? "\(date.formatted(short)) \(date.formatted(clock))" : date.formatted(short)
    }

    /// タスクの行の右に出す短い表記。残りだけを出す。
    static func taskLabel(_ due: String, now: Date = Date()) -> (text: String, overdue: Bool)? {
        remaining(due, now: now)
    }

    /// 北極星の期限。「10/5 18:00まで・あと4日」。
    static func starLabel(_ due: String, now: Date = Date()) -> (text: String, overdue: Bool)? {
        guard let left = remaining(due, now: now), let when = whenText(due) else { return nil }
        return ("\(when)まで・\(left.text)", left.overdue)
    }

    /// 予約の日時。「10/3 9:00に浮上」。
    static func surfaceLabel(_ date: Date) -> String {
        "\(date.formatted(.dateTime.month(.defaultDigits).day().hour().minute()))に今日の北極星へ"
    }

    /// タスクの期限メニューに並べる候補。時間で区切るものと、日で区切るもの。
    static func presets(now: Date = Date(), calendar: Calendar = .current) -> [(label: String, value: String)] {
        let today = calendar.startOfDay(for: now)
        func add(_ days: Int) -> Date { calendar.date(byAdding: .day, value: days, to: today) ?? today }
        func hoursLater(_ hours: Int) -> Date {
            // 5分刻みに切り上げて、半端な時刻にしない。
            let raw = now.addingTimeInterval(Double(hours) * 3600)
            let step = 300.0
            return Date(timeIntervalSinceReferenceDate: (raw.timeIntervalSinceReferenceDate / step).rounded(.up) * step)
        }
        var items: [(String, String)] = []
        for hours in [1, 3] {
            let at = hoursLater(hours)
            items.append(("\(hours)時間後（\(at.formatted(clock))）", string(dateTime: at)))
        }
        items.append(("今日中", string(today)))
        if let morning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: add(1)) {
            items.append(("明日の朝（9:00）", string(dateTime: morning)))
        }
        items.append(("明日中", string(add(1))))
        // weekday: 日=1 … 土=7
        let weekday = calendar.component(.weekday, from: today)
        let toFriday = (6 - weekday + 7) % 7
        let toMonday = (2 - weekday + 7) % 7 == 0 ? 7 : (2 - weekday + 7) % 7
        if toFriday > 1 { items.append(("今週の金曜（\(add(toFriday).formatted(short))）", string(add(toFriday)))) }
        items.append(("来週の月曜（\(add(toMonday).formatted(short))）", string(add(toMonday))))
        items.append(("1週間後（\(add(7).formatted(short))）", string(add(7))))
        return items
    }

    /// 北極星の期限を決めるときの最初の候補。1週間後の 18:00。
    static func defaultDue(now: Date = Date(), calendar: Calendar = .current) -> String {
        let day = calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: now)) ?? now
        return string(dateTime: calendar.date(bySettingHour: 18, minute: 0, second: 0, of: day) ?? day)
    }
}
