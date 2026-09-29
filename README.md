# Polaris

今日いちばん大事なことを、画面のいちばん手前に置くmacOSアプリです。北極星を1文、いま取り組むことを最大3件に絞り、それ以外は「あとで」に残します。MCPからも同じ状態を読み書きできます。

アプリは全Space・フルスクリーンの上に出る小さな付箋（NSPanel）と、メニューバーのアイコンで動きます。ショートカットは ⌃⌥P（北極星を書き換える）、⌃⌥N（タスクを追加）、⌃⌥O（付箋を操作する）、⌃⌥H（隠す）、⌃⌥T（クリック透過）です。製品仕様は [docs/product.md](docs/product.md)、画面仕様は [docs/design.md](docs/design.md) を参照してください。

## ビルド

macOS 14以上、Swift 6対応のCommand Line Toolsが必要です。外部パッケージやXcodeプロジェクトは使いません。

```sh
swift build
make test
make app
open build/Polaris.app
```

`make build` は `swift build` を実行します。`make test` はSwift Testingのテストを実行します。`make app` はreleaseビルドを `build/Polaris.app` にまとめ、Developer ID Application証明書があればその証明書で、なければアドホック署名します。公証は行いません。アイコンを追加する場合は `Resources/Polaris.icns` を配置してください。

`make snapshots` はアプリに `--render-snapshots snapshots/` を渡し、主要な状態をライト・ダーク（一部はコントラスト強調とモード違いも）でPNGに書き出して終了します。ウィンドウは出しません。ImageRendererは素材を描けないので、地は不透明の `surface` で近似します。

```sh
make install
claude mcp add polaris -- /Applications/Polaris.app/Contents/MacOS/polaris-mcp
```

`make install` は既存の `/Applications/Polaris.app` を削除してコピーします。状態データは削除しません。インストールは書き込み権限のあるアカウントで実行してください。

Command Line Tools単体のSwift 6.3.2では、素の `swift test` がテスト0件で終了する問題を確認しています。`make test` はこの環境を検出し、生成ランナーにも `Testing.framework` の探索パスを渡します。Xcode環境では通常の `swift test` を実行します。

実行ファイルを使ったstdio往復・6プロセスの並行更新は、Python 3がある環境で次のように検証できます。

```sh
python3 scripts/polaris-backend-smoke.py
```

## データとMCP

状態は `~/.polaris/state.json` に保存します。`POLARIS_HOME` にディレクトリを指定すると保存先を切り替えられます。アプリとMCPを同じ状態につなぐ場合は同じ保存先を指定してください。state.json が壊れて読めないときは、メニューバーの「状態を作り直す」で `state.corrupt-<日時>.json` に退避して新しく始められます。

- JSONの日時はISO 8601、日のキーはローカル時刻の `YYYY-MM-DD` です。
- `state.lock` をflockでロックし、最新の状態に変更を適用して、一時ファイルからrenameします。実際に状態が変わった書き込みでrevisionが1増えます。初回作成はrevision 1です。
- 日付が進んだ最初の読み書きで前日を履歴に移し、未完了のnowをlaterの先頭へ戻します。モードは仕事の日、北極星は空になります。履歴は過去90暦日以内で最大90件です。
- nowが満杯なら追加・移動先はlater末尾になり、`Placement.overflowed` がtrueになります。positionは0始まりで、リスト長を超える位置は末尾扱いです。
- 完了したタスクをmoveすると未完了に戻ります。履歴中のタスクは変更しません。
- bannerは1件です。既定5分、最大1440分で、読み書きや監視時に期限切れを除去します。
- 壊れたJSONや未対応schemaVersionはエラーにし、既存データを上書きしません。

MCPは改行区切りJSON-RPC 2.0のstdioサーバーです。標準出力には応答だけを書きます。[MCPのinitializeとツール応答形式](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/docs/specification/2025-06-18/schema.mdx)を利用し、2024-11-05、2025-03-26、2025-06-18をネゴシエートできます。

12個のツールを提供します: `polaris_get_today`, `polaris_set_north_star`, `polaris_set_mode`, `polaris_list_modes`, `polaris_add_task`, `polaris_complete_task`, `polaris_move_task`, `polaris_remove_task`, `polaris_rename_task`, `polaris_list_later`, `polaris_nudge`, `polaris_get_history`。タイトルと北極星は200字、nudge の text は280字までです。引数の詳細は `tools/list` のinputSchemaで取得できます。追加先はlaterが既定です。ユーザーの指示なしにnowを入れ替えないでください。

## UIからの購読

```swift
import PolarisCore

let store = PolarisStore()
let state = try store.read()
let placement = try store.addTask(title: "読む", to: .now)

// UIのライフサイクルに合わせて購読Taskをキャンセルしてください。
// PolarisCore.Taskとの名前衝突を避ける場合は _Concurrency.Task と書けます。
for try await state in store.changes() {
    // MainActor上で画面の状態を更新する
    print(state.revision, state.today.northStar)
}
```

`changes()` は初期状態と新しいrevisionを通知し、遅い購読者には最新1件を保持します。ディレクトリのDispatchSource監視で原子的置換を検知し、1秒間隔の補助タイマーで日付変更とbanner期限も反映します。ファイルエラー時にはthrowして終了します。ストア操作は同期APIなので、大きな履歴を扱う処理はUIのメインスレッド外で行ってください。
