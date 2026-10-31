# Polaris — 今日の北極星を、いつも画面のいちばん手前に

## 解きたい問題

並列で仕事を回しすぎて注意が散り、その日の目標を落とす。

- 重要度1〜5位を並行していると、6〜10位が目に入って1位がおろそかになる
- 本を読む日なのに、ふらっとSlackや仕事用のClaude Codeを開いてしまう

Polarisは「今日いちばん大事なこと」を1つ、常に最前面の小さな付箋に出し続ける。
**見えるものを減らす**ための道具。

## 原則

1. **主役は1つ**。北極星（今日の一番）が常に最も大きく、最も目に入る
2. **見える目標は1つ**。控えは一覧から選び、達成すると次の北極星へ進む
3. **止めない、気づかせる**。寄り道をブロックせず、静かに北極星へ視線を戻す
4. **邪魔しない**。常時最前面だからこそ、小さく・静かに・クリックを奪わない
5. **Macネイティブ**。SwiftUI + AppKit。Electronではない

## データモデル（PolarisCore）

- `Day`: `date`（YYYY-MM-DD, ローカル）, `mode`, `northStar`（1文、空可）, `note`（任意の短文）
- `Mode`: `id`, `label`（例: 仕事の日 / 読書の日 / 休む日）, `symbol`（SF Symbol名）, `tint`（デザイントークン名）, `avoidApps`（bundle ID の配列。前面に来たら寄り道とみなす）
- `banner`: MCPから送られた一時メッセージ（`text`, `from`, `expiresAt`）。1件のみ保持
- `history`: 過去の `Day`（直近90日）
- `modes`: 設定で編集したモード一覧（任意。キーが無ければ既定の3種）。先頭が既定モードで、既定と今日のモードは消せない
- 状態ファイル: `~/.polaris/state.json`（`schemaVersion`, `revision`）。環境変数 `POLARIS_HOME` で上書き可
- 書き込みは一時ファイル→rename の原子的置換。変更のたびに `revision` を+1。アプリとMCPは同じファイルを共有し、アプリはファイル監視で即時反映する。変更操作は必ず「最新を読み直す→適用→書く」で行い、ファイルロック（`flock`）で直列化する

### ルール

- 日付が変わって最初に起動・操作したとき、前日を `history` に移す。モードは既定モードに戻し、UIは「朝の支度」シートを出す（モード選択→北極星を1文の2ステップ）。既存状態の互換フィールドと繰り越し処理は保つ
- 北極星は `Day.star`（`NorthStar`: `id`, `text`, `createdAt`, `activatedAt`, `endedAt`, `outcome`）で持つ。今日に出るのは1つだけで、ほかは `starQueue`（控え、順番つき、追加は20件まで）に置く。終えたもの（`achieved` 達成 / `dropped` 手放した）は `starLog` に最大500件残す。互換のため `northStar` 文字列も書き、キーが無い古い状態は文字列から移行する
- 北極星には期限 `dueDate?`（`YYYY-MM-DD` か `YYYY-MM-DDTHH:mm`）と、控えにあるときだけ予約 `startsAt?`（日時）を付けられる。予約の時刻が来た控えはアプリが今日の北極星に上げ、今日の北極星は控えの先頭へ戻す（時刻が早いものから1つずつ）。達成・手放したときの繰り上げは、まだ時刻が来ていない予約を飛ばす。手で「これにする」を選んだら予約は消す
- 北極星を達成・手放すと、控えの先頭が今日に上がる。今日の北極星を空にすると控えの先頭へ戻す。今日の北極星が無いときに控えと同じ文面を書いたら、新しく作らず控えのものを出す（今日の北極星があるときの書き換えは、その文面の編集）。日付が変わったら、終えていない北極星は履歴に残しつつ控えの先頭へ戻す
- 寄り道検知: 前面アプリが現在モードの `avoidApps` に含まれたら、付箋が控えめに主張して北極星を示す（例:「今日は読書の日。戻る？」）。ブロックはしない。同じアプリで連続して出すのは5分に1回まで

## ウィンドウ（PolarisApp）

- `NSPanel`（nonactivating, floating level, 全Space・フルスクリーン上にも表示, Dockアイコンなし = `LSUIElement`）
- 通常は小さな「付箋」: 北極星の文字。ホバーやつまみで展開すると、北極星の真横に達成ボタン、期限の下に一覧への入口、下段にモードを出す
- 画面の四隅にスナップ。位置は記憶する
- 閉じた付箋は既定でクリックを後ろへ通す（付箋越しに下のアプリを操作できる）。付箋の縁の内側に重ねた小さなつまみだけが触れる場所で、押すと開き、ドラッグで動かす。透過は設定と ⌃⌥T で切り替える。一時的に隠す操作もある
- 開いた付箋では、ボタンや行にポインタを止めると、押すと何が起きるかを吹き出しで案内する
- 閉じた付箋の地の透明度を設定で 0〜80% に変えられる。文字は薄くしない
- メニューバーアイコン: 表示/非表示の次に「北極星の一覧…」、朝の支度をやり直す、モード切替、設定、終了
- 北極星の一覧: 今日の北極星、控え、これまで（達成/手放した、期間、控えに戻す）。付箋の常設行「北極星の一覧」、右クリック、メニューバー、⌃⌥L から開く。控えがあれば行に「次 〇〇 ほか n」を添え、右端の＋から控えに足せる
- 達成ボタンは開いた付箋の北極星の1行目に上揃えで置く。今日が空で控えがあるときは「これにする」で先頭を今日に出す
- グローバルショートカット ⌃⌥P で北極星だけのクイック編集、⌃⌥L で一覧を開く。北極星が空なら「北極星を設定する」から書ける
- ライト/ダーク両対応、`NSVisualEffectView` 系の素材感、Reduce Motion / Increase Contrast 対応
- 開発・デザインレビュー用に `Polaris --render-snapshots <dir>` で主要状態をPNGに書き出せる（ImageRenderer使用、ウィンドウは出さない）

## MCP（polaris-mcp）

- stdio の MCP サーバー。依存ライブラリなしの手書き JSON-RPC 2.0（行区切り）。Swift 実行ファイル、PolarisCore を共有
- `.app` 内の `Contents/MacOS/polaris-mcp` に同梱。`claude mcp add polaris -- /Applications/Polaris.app/Contents/MacOS/polaris-mcp`
- 別に置いた古い `polaris-mcp` は `modes` などの新しいキーを知らず、書き込むと消してしまう。必ず `.app` に同梱したものを登録する
- ツール:
  - `polaris_get_today` — 今日の状態（モード・北極星・控え・banner）
  - `polaris_set_north_star(text)`
  - `polaris_set_mode(mode_id)` / `polaris_list_modes`
  - `polaris_nudge(text, ttl_minutes?)` — 付箋に一時メッセージを出す（例: エージェントが「PR終わったよ、北極星に戻ろう」）
  - `polaris_get_history(days?)`
  - `polaris_update_north_star(id, text?, dueDate?, startsAt?)` — 期限と予約を決める。キーが無ければ据え置き、null で外す。予約は控えの北極星だけ
  - `polaris_list_north_stars` / `polaris_add_north_star(text, position?, dueDate?, startsAt?)` / `polaris_complete_north_star(outcome?)` / `polaris_switch_north_star(id)` / `polaris_remove_north_star(id)` / `polaris_get_north_star_log(limit?)` — 北極星の控えとログ
- ツールの説明文は、今日の北極星を1つに絞って集中を守る道具であることを伝える。日ごとの返り値にも互換専用の旧項目を含めない

## 構成

- Swift Package（Swift 6, macOS 14+）。Xcodeプロジェクトは作らない
  - `PolarisCore`（library）: モデル・ストア・日付ロールオーバー・ルール
  - `PolarisApp`（executable）: SwiftUI + AppKit
  - `polaris-mcp`（executable）
  - `PolarisCoreTests` / `PolarisMCPTests`
- `scripts/bundle.sh`: release ビルド → `build/Polaris.app` を組み立て（Info.plist, 両実行ファイル, アイコン）→ 署名（Developer ID があれば使用、無ければアドホック）
- `Makefile`: `make build` / `make test` / `make app` / `make snapshots` / `make install`
