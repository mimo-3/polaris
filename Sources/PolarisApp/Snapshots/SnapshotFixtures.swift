import Foundation
import PolarisCore

/// スナップショット用の固定データ。日付や ID を固定して、毎回同じ絵になるようにする。
enum Fixtures {
    static let date = "2026-09-30"
    static let created = Date(timeIntervalSince1970: 1_790_000_000)

    static func task(_ n: Int, _ title: String, source: String = "user") -> Item {
        Item(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!, title: title,
             createdAt: created, source: source)
    }

    static func mode(_ id: String) -> Mode { Mode.defaults.first { $0.id == id }! }

    static let work = [task(1, "レビュー指摘を直す"), task(2, "CIの遅いテストを分ける"), task(3, "採用面接の評価を書く")]
    static let later = [task(10, "議事録を整える"), task(11, "オンボーディング資料の図を差し替える", source: "mcp:claude-code"),
                        task(12, "経費精算"), task(13, "1on1の議題を決める"), task(14, "依存ライブラリの更新"),
                        task(15, "ブログの下書きを読む"), task(16, "Slackの通知設定を見直す")]
    static let done = [completed(task(20, "朝会のメモを共有")), completed(task(21, "PRをマージ"))]

    static func completed(_ task: Item) -> Item {
        var t = task
        t.completedAt = created
        return t
    }

    static let shortStar = "決済APIの移行を本番へ出す"
    static let longStar = "決済APIの移行を今日中に本番へ出す"

    static func state(mode: String = "work", northStar: String = longStar, now: [Item] = work,
                      done: [Item] = done, later: [Item] = later, banner: Banner? = nil, history: [Day] = []) -> AppState {
        let modeValue = self.mode(mode)
        var nowItems = now
        if mode == "reading" && now == work {
            nowItems = [task(4, "2章の要点を3行でメモ"), task(5, "付箋に引用を書き出す")]
        }
        if mode == "rest" && now == work {
            nowItems = [task(6, "散歩して昼寝する")]
        }
        return AppState(revision: 1, today: Day(date: date, mode: modeValue, northStar: northStar, now: nowItems, done: done),
                     later: later, banner: banner, history: history)
    }

    static let readingStar = "『遅いインターネット』を3章まで読む"
    static let restStar = "何もしない。明日のために休む"

    static func star(for mode: String) -> String {
        switch mode {
        case "reading": readingStar
        case "rest": restStar
        default: longStar
        }
    }

    static var yesterday: Day {
        Day(date: "2026-09-29", mode: mode("work"), northStar: "決済APIの移行を本番へ出す",
            now: [task(1, "レビュー指摘を直す")], done: [])
    }

    // MARK: 北極星の控えと振り返り

    static func starID(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0001-%012d", n))! }

    static let queuedStars = [NorthStar(id: starID(1), text: "CS成長PJのキックオフを終える", createdAt: created,
                                        dueDate: DueDates.string(Date().addingTimeInterval(3 * 86400))),
                              NorthStar(id: starID(2), text: "採用の評価基準を見直す", createdAt: created,
                                        startsAt: StarDates.nextMorning(after: Date())),
                              NorthStar(id: starID(5), text: "四半期の振り返りを書く", createdAt: created)]

    static let pastStars: [NorthStar] = {
        let day: TimeInterval = 86400
        return [NorthStar(id: starID(3), text: "東京ガスの提案方針を整理する", createdAt: created - 3 * day,
                          activatedAt: created - 2 * day, endedAt: created - day, outcome: .achieved),
                NorthStar(id: starID(4), text: "社内勉強会の資料を作る", createdAt: created - 5 * day,
                          activatedAt: created - 5 * day, endedAt: created - 4 * day, outcome: .dropped)]
    }()

    /// `promoted` なら控えの先頭が今日に上がったあと（残りの控えは1件）。
    static func withStars(_ state: AppState, promoted: Bool = false) -> AppState {
        var s = state
        s.starQueue = promoted ? Array(queuedStars.dropFirst()) : queuedStars
        s.starLog = pastStars
        if !promoted { s.today.star?.dueDate = DueDates.string(Date().addingTimeInterval(4 * 86400)) }
        return s
    }
}
