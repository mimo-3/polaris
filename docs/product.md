# Polaris — 今日の北極星を、いつも画面のいちばん手前に

## 解きたい問題

並列で仕事を回しすぎて注意が散り、その日の本命を落とす。

- 重要度1〜5位を並行していると、6〜10位が目に入って1位がおろそかになる
- 本を読む日なのに、ふらっとSlackや仕事用のClaude Codeを開いてしまう

Polarisは「今日いちばん大事なこと」を1つ、常に最前面の小さな付箋に出し続ける。
タスク管理ツールではない。**見えるものを減らす**ための道具。

## 原則

1. **主役は1つ**。北極星（今日の一番）が常に最も大きく、最も目に入る
2. **同時に見えるのは最大3つ**。4つ目以降は自動で「あとで」に送られ、件数しか見えない
3. **止めない、気づかせる**。寄り道をブロックせず、静かに北極星へ視線を戻す
4. **邪魔しない**。常時最前面だからこそ、小さく・静かに・クリックを奪わない
5. **Macネイティブ**。SwiftUI + AppKit。Electronではない

## データモデル（PolarisCore）

- `Day`: `date`（YYYY-MM-DD, ローカル）, `mode`, `northStar`（1文、空可）, `now`（最大3件・順序あり、先頭が本命）, `done`（今日完了したもの）, `note`（任意の短文）
- `Mode`: `id`, `label`（例: 仕事の日 / 読書の日 / 休む日）, `symbol`（SF Symbol名）, `tint`（デザイントークン名）, `avoidApps`（bundle ID の配列。前面に来たら寄り道とみなす）
- `Task`: `id`(UUID), `title`, `createdAt`, `completedAt?`, `source`（`user` | `mcp:<client名>`）
- `later`: 日をまたいで残る「あとで」リスト（上限なし、UIでは件数のみ表示、展開時だけ中身が見える）
- `banner`: MCPから送られた一時メッセージ（`text`, `from`, `expiresAt`）。1件のみ保持
- `history`: 過去の `Day`（直近90日）
- `modes`: 設定で編集したモード一覧（任意。キーが無ければ既定の3種）。先頭が既定モードで、既定と今日のモードは消せない
- `lastOverflow`: 直近に `now` から溢れた記録（`taskID`, `title`, `source`, `at`）。`source` はタスクを作った側ではなく、その操作をした側（`user` | `mcp:<client名>`）
- 状態ファイル: `~/.polaris/state.json`（`schemaVersion`, `revision`）。環境変数 `POLARIS_HOME` で上書き可
- 書き込みは一時ファイル→rename の原子的置換。変更のたびに `revision` を+1。アプリとMCPは同じファイルを共有し、アプリはファイル監視で即時反映する。変更操作は必ず「最新を読み直す→適用→書く」で行い、ファイルロック（`flock`）で直列化する

### ルール

- `now` に4件目を追加しようとしたら、追加せず `later` に入れ、その旨を結果で返す（UIでもMCPでも同じ）
- 本命（`now[0]`）を完了したら、次が繰り上がる
- 日付が変わって最初に起動・操作したとき、前日を `history` に移し、未完了の `now` は `later` の先頭に戻す。モードは既定モードに戻す。UIは「朝の支度」シートを出す（モード選択→北極星を1文→`later` から最大3件を選ぶ）
- 北極星は `Day.star`（`NorthStar`: `id`, `text`, `createdAt`, `activatedAt`, `endedAt`, `outcome`）で持つ。今日に出るのは1つだけで、ほかは `starQueue`（控え、順番つき、追加は20件まで）に置く。終えたもの（`achieved` 達成 / `dropped` 手放した）は `starLog` に最大500件残す。互換のため `northStar` 文字列も書き、キーが無い古い状態は文字列から移行する
- 北極星を達成・手放すと、控えの先頭が今日に上がる。今日の北極星を空にすると控えの先頭へ戻す。今日の北極星が無いときに控えと同じ文面を書いたら、新しく作らず控えのものを出す（今日の北極星があるときの書き換えは、その文面の編集）。日付が変わったら、終えていない北極星は履歴に残しつつ控えの先頭へ戻す
- 寄り道検知: 前面アプリが現在モードの `avoidApps` に含まれたら、付箋が控えめに主張して北極星を示す（例:「今日は読書の日。戻る？」）。ブロックはしない。同じアプリで連続して出すのは5分に1回まで

## ウィンドウ（PolarisApp）

- `NSPanel`（nonactivating, floating level, 全Space・フルスクリーン上にも表示, Dockアイコンなし = `LSUIElement`）
- 通常は小さな「付箋」: 北極星 + 本命1件 + モード表示。ホバーで展開して `now` 3件と `later` 件数、完了操作
- 画面の四隅にスナップ。位置は記憶する
- クリック透過モード（付箋越しに下のアプリを操作できる）と、一時的に隠す操作
- メニューバーアイコン: 表示/非表示、朝の支度をやり直す、北極星を達成して次へ・控えから選ぶ・控えと振り返りの窓、モード切替、設定、終了
- 北極星の控えと振り返りの窓: 今日の北極星、控え（並べ替え・削除・今日に出す・追加）、これまで（達成/手放した、期間、控えに戻す）
- グローバルショートカットで編集（北極星の書き換え・タスク追加）を開く
- ライト/ダーク両対応、`NSVisualEffectView` 系の素材感、Reduce Motion / Increase Contrast 対応
- 開発・デザインレビュー用に `Polaris --render-snapshots <dir>` で主要状態をPNGに書き出せる（ImageRenderer使用、ウィンドウは出さない）

## MCP（polaris-mcp）

- stdio の MCP サーバー。依存ライブラリなしの手書き JSON-RPC 2.0（行区切り）。Swift 実行ファイル、PolarisCore を共有
- `.app` 内の `Contents/MacOS/polaris-mcp` に同梱。`claude mcp add polaris -- /Applications/Polaris.app/Contents/MacOS/polaris-mcp`
- 別に置いた古い `polaris-mcp` は `modes` などの新しいキーを知らず、書き込むと消してしまう。必ず `.app` に同梱したものを登録する
- ツール:
  - `polaris_get_today` — 今日の状態（モード・北極星・now・done・later件数・banner）
  - `polaris_set_north_star(text)`
  - `polaris_set_mode(mode_id)` / `polaris_list_modes`
  - `polaris_add_task(title, to: "now"|"later", position?)` — nowが満杯なら later に入り、その旨を返す
  - `polaris_complete_task(id)` / `polaris_move_task(id, to, position?)` / `polaris_remove_task(id)`
  - `polaris_list_later`
  - `polaris_nudge(text, ttl_minutes?)` — 付箋に一時メッセージを出す（例: エージェントが「PR終わったよ、本命に戻ろう」）
  - `polaris_get_history(days?)`
  - `polaris_list_north_stars` / `polaris_add_north_star(text, position?)` / `polaris_complete_north_star(outcome?)` / `polaris_switch_north_star(id)` / `polaris_remove_north_star(id)` / `polaris_get_north_star_log(limit?)` — 北極星の控えとログ
- ツールの説明文には「ユーザーの集中を守るための道具なので、`now` を勝手に入れ替えない。追加は `later` を既定にする」旨を書く

## 構成

- Swift Package（Swift 6, macOS 14+）。Xcodeプロジェクトは作らない
  - `PolarisCore`（library）: モデル・ストア・日付ロールオーバー・ルール
  - `PolarisApp`（executable）: SwiftUI + AppKit
  - `polaris-mcp`（executable）
  - `PolarisCoreTests` / `PolarisMCPTests`
- `scripts/bundle.sh`: release ビルド → `build/Polaris.app` を組み立て（Info.plist, 両実行ファイル, アイコン）→ 署名（Developer ID があれば使用、無ければアドホック）
- `Makefile`: `make build` / `make test` / `make app` / `make snapshots` / `make install`
