import Foundation
import PolarisCore

/// design.md 5章の文言。UI の文字列はここにまとめ、ビューに直接書かない。
enum Copy {
    // 付箋
    static let northStarEmpty = "北極星を設定する"
    /// 押せない場所（メニューバー・寄り道表示・控えの窓）で使う。
    static func modeMenu(_ label: String) -> String { "モード、\(label)。押すと切り替える" }
    static let northStarEmptyHint = "押すと今日の北極星を書ける"
    static let settingsDisplay = "表示"
    static let settingsOpacity = "付箋の地の透明度"
    static let settingsOpacityDetail = "閉じているときだけ。文字は薄くならない"
    static let settingsClickThrough = "閉じた付箋のクリックを通す"
    static let settingsClickThroughDetail = "後ろの窓を触れる。脇のつまみで開く・動かす（⌃⌥T）"
    static let settingsCelebrate = "達成したときの演出"
    static let settingsCelebrateDetail = "北極星を達成すると、星が弾ける"
    static let settingsSound = "演出の音"
    static let settingsShortcuts = "ショートカット"
    static func shortcutConflict(_ key: String) -> String { "\(key) はほかのアプリが使っている。別のキーを選んで。" }
    static let settingsStartup = "起動"
    static let settingsOpenAtLogin = "Mac にログインしたら Polaris を開く"
    static let settingsMCP = "AI との連携（MCP）"
    static let settingsMCPDetail = "Claude Code などから、北極星を読み書きできるようになる。"
    static let settingsCopy = "コマンドをコピー"
    static let settingsCopied = "コピーした"
    static let settingsOpen = "設定を開く"
    static func starSurfaced(_ title: String) -> String { "「\(title)」の時間になった" }
    static let panelToggle = "付箋の開閉"
    static let northStarNone = "北極星は未設定"
    static let queueStarPlaceholder = "控えに入れる北極星を1行で"
    static let queueStarAdd = "控えに北極星を足す"
    static let delete = "削除"

    // 声の行
    // 声の行は1行に収める。タイトルは「と」の間で末尾を省略するので、前後に分けて持つ。
    static let quoteOpen = "「"
    static let undo = "取り消す"
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

    // 朝の支度
    static let morning = "朝の支度"
    static func step(_ n: Int) -> String { "\(n) / 2" }
    static let step1Title = "今日はどんな日？"
    static let noAvoid = "寄り道は知らせない"
    static let writeNorthStar = "北極星を書く"
    static let step2Title = "今日いちばん大事なことを1文で"
    static let step2Placeholder = "例: 決済APIの移行を本番に出す"
    static let startWithStar = "この北極星で始める"
    static let step2Hint = "1文で書けないなら、まだ絞れていない。"
    static let carryOver = "昨日の北極星を引き継ぐ："
    static let skipNorthStar = "北極星なしで進む"
    static let back = "戻る"

    // クイック編集
    static let northStarLabel = "北極星"
    /// ⌥⏎ は今日には出さずに控えへ入れる。
    static let quickHintsStar = ["⏎ 保存する", "⌥⏎ 控えに入れる", "esc 閉じる"]

    // 北極星の控えと振り返り
    static func starNext(_ text: String) -> String { "次 \(text)" }
    static func starMore(_ count: Int) -> String { "ほか \(count)" }
    static let starAchieved = "達成した"
    static let starDrop = "手放す"
    static let starUseNext = "これにする"
    static let starAchievedTail = "」を達成。"
    static let starDroppedTail = "」を手放した。"
    static func starEndedSpoken(_ title: String, next: String?, achieved: Bool) -> String {
        let head = achieved ? "\(title)を達成した。" : "\(title)を手放した。"
        return next.map { head + "次の北極星は\($0)" } ?? head + "控えはもうない"
    }
    static let starsOpenHint = "控えの並べ替えと、これまでの北極星を開く"
    static let starsQueueFull = "控えは\(TextRules.starQueueMax)件まで。北極星の一覧で減らしてから入れて。"
    static let starsWindowMenu = "北極星の一覧…"
    static let starsWindowTitle = "北極星の一覧"
    static let starsToday = "今日の北極星"
    static let starsQueue = "控え"
    static let starsLog = "これまで"
    static let starsLogEmpty = "終えた北極星はまだない。達成するとここに残る。"
    static let starsQueuePlaceholder = "控えに入れる北極星を1文で"
    static let starsQueueAdd = "控えに入れる"
    static let starsMoveUp = "上へ"
    static let starsMoveDown = "下へ"
    static let starsDue = "期限"
    static let starsDueNone = "決めていない"
    static let starsDueSet = "決める"
    static let starsDueClear = "期限を外す"
    static let starsStart = "今日の北極星にする日時"
    static let starsStartDetail = "その時刻になったら、付箋の1段目に上がって知らせる"
    static let starsStartClear = "予約を外す"
    static let starsEditHint = "押すと期限と予約を決められる"
    static func starsDelete(_ title: String) -> String { "「\(title)」を削除" }
    static func starsLogMore(_ count: Int) -> String { "ほか\(count)件を見る" }
    static let starsLogLess = "たたむ"
    static let starsReopen = "控えに戻す"
    static let starOutcomeAchieved = "達成"
    static let starOutcomeDropped = "手放した"
    static let starsQueueHelp = "ドラッグで並べ替え。今日の北極星を達成すると、いちばん上が付箋に上がる。"

    // メニューバー
    static let hideNote = "付箋を隠す"
    static let showNote = "付箋を表示する"
    static let hide15 = "15分だけ隠す"
    static let clickThrough = "閉じた付箋のクリックを通す"
    static let editNorthStar = "北極星を書き換える…"
    static let redoMorning = "朝の支度をやり直す…"
    static let modeMenu = "モード"
    static let cornerMenu = "付箋を置く隅"
    static let settings = "設定…"
    static let quit = "Polarisを終了"
    static let handleLabel = "付箋のつまみ"
    static let handleHelpClosed = "クリックで開く・ドラッグで動かす"
    static let handleHelpOpen = "クリックで閉じる・ドラッグで動かす"
    static let expandAction = "展開する"
    static let collapseAction = "たたむ"
    static let expandedValue = "展開中"
    static let collapsedValue = "たたんでいる"
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
        let name = raw.lowercased().hasPrefix("mcp:")
            ? String(raw.dropFirst(4)).trimmingCharacters(in: .whitespaces) : raw
        let known = ["claude-code": "Claude Code", "claude-ai": "Claude", "claude": "Claude",
                     "codex": "Codex", "codex-mcp-client": "Codex", "cursor": "Cursor", "cursor-vscode": "Cursor"]
        return known[name.lowercased()] ?? name
    }
}

/// ホバーで出す案内。押すと何が起きるかを一言で書く。
enum Hint {
    static let star = "クリックで期限と控え・ダブルクリックで書き直す"
    static let starEmpty = "今日の北極星を決める"
    static let starQueue = "北極星の一覧を開く"
    static let starAchieve = "達成にして、次の控えを今日の北極星にする"
    static let starUseNext = "先頭の控えを今日の北極星にする"
    static let queueStar = "控えに北極星を足す"
    static let mode = "今日のモードを切り替える"
    static let settings = "設定を開く（透明度・クリック透過・ショートカットなど）"
}
