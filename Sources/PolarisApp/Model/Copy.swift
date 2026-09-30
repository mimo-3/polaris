import Foundation
import PolarisCore

/// design.md 5章の文言。UI の文字列はここにまとめ、ビューに直接書かない。
enum Copy {
    // 付箋
    static let northStarEmpty = "北極星を設定する"
    /// 押せない場所（メニューバー・寄り道表示・控えの窓）で使う。
    static func modeMenu(_ label: String) -> String { "モード、\(label)。押すと切り替える" }
    static let panelToggle = "付箋の開閉"
    static let northStarNone = "北極星は未設定"
    static let startMorning = "朝の支度を始める"
    static let addLead = "本命を追加する"
    static let add = "＋ 追加"
    static let addPlaceholder = "やることを1行で"
    static func later(_ n: Int) -> String { "あとで \(n)" }
    static let laterFullSuffix = "・いまは満杯"
    static let laterEmpty = "あとでは空"
    static let moveToNow = "いまに入れる"
    static func done(_ n: Int) -> String { "済 \(n)" }
    static let makeLead = "本命にする"
    static let sendLater = "あとでに送る"
    static let rename = "名前を変える"
    static let delete = "削除"
    static let allDone = "今日の分は済んだ"
    static let closeDay = "今日はここまで"
    static func dayClosed(_ mode: String) -> String { "\(mode)・今日はここまで" }

    // 声の行
    // 声の行は1行に収める。タイトルは「と」の間で末尾を省略するので、前後に分けて持つ。
    static let quoteOpen = "「"
    static let completedTail = "」を完了にした。"
    static func completed(_ title: String) -> String { "「\(title)」を完了にした。" }
    static let undo = "取り消す"
    static let overflowTail = "」はあとでへ"
    static func overflow(_ title: String) -> String { "「\(title)」はあとでに入れた。" }
    static func fromClient(_ client: String) -> String { "（\(client) から）" }
    static let swap = "入れ替える…"
    static let swapPick = "入れ替える行を選ぶ"
    static let swapCancel = "やめる"
    static let swapWithThis = "入れ替える"
    /// 声の行の寄り道。「今日は」を省いて1行に収める。
    static func detour(_ mode: Mode) -> String {
        mode.id == "rest" ? "\(mode.label)。離れる？" : "\(mode.label)。戻る？"
    }
    static func hideApp(_ app: String) -> String { "\(app)を隠す" }
    static let fiveMinutes = "5分だけ見る"
    static let fiveMinutesShort = "5分"
    static func from(_ client: String) -> String { "\(client) から" }
    static func bannerFrom(_ client: String) -> String { " · \(client)" }
    static func dismissBanner(_ client: String) -> String { "\(client) からのメッセージを閉じる" }
    static let saveFailed = "保存できなかった。~/.polaris に書き込めるか確認して。"
    static let loadFailed = "今日の内容を読めなかった。メニューの「状態を作り直す」で戻せる。"
    static let resetState = "状態を作り直す（読めないファイルは退避する）"
    static let fromYesterday = "昨日から"

    // 朝の支度
    static let morning = "朝の支度"
    static func step(_ n: Int) -> String { "\(n) / 3" }
    static let step1Title = "今日はどんな日？"
    static func avoidNote(_ apps: [String]) -> String { "\(apps.joined(separator: "・")) を寄り道として知らせる" }
    static let noAvoid = "寄り道は知らせない"
    static let writeNorthStar = "北極星を書く"
    static let step2Title = "今日いちばん大事なことを1文で"
    static let step2Placeholder = "例: 決済APIの移行を本番に出す"
    static let step2Hint = "1文で書けないなら、まだ絞れていない。"
    static let carryOver = "昨日の北極星を引き継ぐ："
    static let pickThree = "いまの3件を選ぶ"
    static let skipNorthStar = "北極星なしで進む"
    static let step3Title = "いまやることを3つまで"
    static let step3Hint = "最初に選んだものが本命になる"
    static let writeNew = "＋ 新しく書く"
    static let laterEmptyMorning = "あとでは空。新しく書くか、北極星だけで始めよう。"
    static func startWith(_ n: Int) -> String { n == 0 ? "北極星だけで始める" : "この\(n)件で始める" }
    static let back = "戻る"

    // クイック編集
    static let northStarLabel = "北極星"
    static let addLabel = "追加"
    static func toNow(_ remaining: Int) -> String { "いまに入れる（残り\(remaining)枠）" }
    static let toLaterFull = "あとでに入れる（いまは3件で満杯）"
    static let quickHints = ["⏎ 保存する", "⌥⏎ あとでに入れる", "esc 閉じる"]
    /// 北極星の欄にいるときのヒント。⌥⏎ はタスクと同じく「今日には出さずに取っておく」。
    static let quickHintsStar = ["⏎ 保存する", "⌥⏎ 控えに入れる", "esc 閉じる"]

    // 北極星の控えと振り返り
    static let starAchieved = "達成した"
    static let starDrop = "手放す"
    static let starUseNext = "これにする"
    static let starNextLabel = "次"
    static let starQueueHead = "控えから出す"
    static func starMore(_ n: Int) -> String { "ほか\(n)" }
    static let starAchievedTail = "」を達成。"
    static let starDroppedTail = "」を手放した。"
    static func starEndedSpoken(_ title: String, next: String?, achieved: Bool) -> String {
        let head = achieved ? "\(title)を達成した。" : "\(title)を手放した。"
        return next.map { head + "次の北極星は\($0)" } ?? head + "控えはもうない"
    }
    static let starsQueueEmpty = "控えはない"
    static let starsOpenHint = "控えの並べ替えと、これまでの北極星を開く"
    static let starsQueueFull = "控えは\(TextRules.starQueueMax)件まで。振り返りの窓で減らしてから入れて。"
    static let starsWindowMenu = "北極星の控えと振り返り…"
    static let starsWindowTitle = "北極星"
    static let starsToday = "今日"
    static let starsQueue = "控え"
    static let starsLog = "これまで"
    static let starsLogEmpty = "終えた北極星はまだない。達成するとここに残る。"
    static let starsQueuePlaceholder = "控えに入れる北極星を1文で"
    static let starsQueueAdd = "控えに入れる"
    static let starsMoveUp = "上へ"
    static let starsMoveDown = "下へ"
    static let starsReopen = "控えに戻す"
    static let starOutcomeAchieved = "達成"
    static let starOutcomeDropped = "手放した"
    static let starsQueueHelp = "今日の北極星を達成すると、いちばん上が付箋に上がる。"

    // メニューバー
    static let hideNote = "付箋を隠す"
    static let showNote = "付箋を表示する"
    static let hide15 = "15分だけ隠す"
    static let clickThrough = "クリック透過"
    static let editNorthStar = "北極星を書き換える…"
    static let addTask = "タスクを追加…"
    static let redoMorning = "朝の支度をやり直す…"
    static let modeMenu = "モード"
    static let cornerMenu = "付箋を置く隅"
    static let settings = "設定…"
    static let quit = "Polarisを終了"
    static let clickThroughIcon = "クリック透過中。⌃⌥T で戻す"
    static let expandAction = "展開する"
    static let collapseAction = "たたむ"
    static let expandedValue = "展開中"
    static let collapsedValue = "たたんでいる"
    static let completeHint = "押すと完了にする"
    static let expandHint = "押すと付箋を展開する"
    static let collapseHint = "押すと付箋をたたむ"
    static func modeChanged(_ label: String) -> String { "\(label)に切り替えた" }

    // MARK: 設定
    static let modesSection = "モード"
    static let addMode = "モードを追加"
    static let newModeLabel = "新しいモード"
    static let modeName = "名前"
    static let defaultBadge = "既定"
    static let todayBadge = "今日"
    static let avoidAppsTitle = "寄り道とみなすアプリ"
    static let pickApps = "アプリを選ぶ…"
    static let removeApp = "外す"
    static func removeAppLabel(_ app: String) -> String { "\(app)を寄り道から外す" }
    static let deleteMode = "このモードを削除"
    static let cannotDeleteDefault = "既定のモードは削除できない。日付が替わるとこのモードに戻る。"
    static let cannotDeleteCurrent = "今日使っているモードは削除できない。別のモードに替えてから消して。"
    static let pickAppsPrompt = "寄り道に加える"

    /// MCP クライアント名を人が読む名前にする。知らない名前はそのまま出す。
    static func clientName(_ raw: String) -> String {
        let name = raw.hasPrefix("mcp:") ? String(raw.dropFirst(4)) : raw
        let known = ["claude-code": "Claude Code", "claude-ai": "Claude", "claude": "Claude",
                     "codex": "Codex", "codex-mcp-client": "Codex", "cursor": "Cursor", "cursor-vscode": "Cursor"]
        return known[name.lowercased()] ?? name
    }
}
