# Polaris

[English](README.en.md)

今日いちばん大事なことを画面のいちばん手前に置くmacOSアプリです。北極星を1文に決め、付箋には今日の目標だけを出します。ほかの目標は控えへ入れ、達成すると次が今日の北極星になります。モードは「仕事の日」「読書の日」「休む日」のような1日の過ごし方です。モードごとに避けたいアプリを決めておくと、そのアプリが前面に来たときに付箋が北極星を示します。

MCPサーバーは `polaris-mcp` としてアプリに同梱しています。AIエージェントなどのMCPクライアントから、アプリと同じ状態を読み書きできます。

アプリは全Space・フルスクリーンの上に出る小さな付箋と、メニューバーのアイコンで動きます。ショートカットは次のとおりです。

- ⌃⌥P: 北極星を書き換える
- ⌃⌥L: 北極星の一覧を開く
- ⌃⌥O: 付箋を操作する
- ⌃⌥H: 隠す
- ⌃⌥T: クリックを透過する

製品仕様は [docs/product.md](docs/product.md)、画面仕様は [docs/design.md](docs/design.md) にあります。

開いた付箋の北極星の真横にある✓で達成します。期限の下の「北極星の一覧」は控えが空でも表示され、メニューバーや⌃⌥Lからも開けます。右端の＋から控えへ足せます。クイック編集は北極星だけで、⌥⏎なら今日を変えず控えに入れます。

## ビルド

macOS 14以上とSwift 6対応のCommand Line ToolsかXcodeが必要です。外部パッケージやXcodeプロジェクトは使いません。

```sh
swift build
make test
make app
open build/Polaris.app
```

`make app` はreleaseビルドを `build/Polaris.app` にまとめて署名します。人に配るアプリは `SIGNING_IDENTITY` に署名IDを指定してビルドしてください。省略するとアドホック署名になります。

## インストールとMCPの接続

```sh
make install
claude mcp add polaris -- /Applications/Polaris.app/Contents/MacOS/polaris-mcp
```

`make install` は新しいアプリを `/Applications` にコピーしてから、既存の `Polaris.app` と入れ替えます。途中で失敗したときは既存のアプリをそのまま残します。状態データは削除しません。インストールは `/Applications` に書き込めるアカウントで実行します。

Claude Code以外のMCPクライアントでは、stdioで起動するコマンドに `/Applications/Polaris.app/Contents/MacOS/polaris-mcp` を指定します。Claude Desktopなら設定ファイルに次のように書きます。

```json
{
  "mcpServers": {
    "polaris": {
      "command": "/Applications/Polaris.app/Contents/MacOS/polaris-mcp"
    }
  }
}
```

`INSTALL_DIR` で入れ替え先を変えたときは、コマンドも `<INSTALL_DIR>/Polaris.app/Contents/MacOS/polaris-mcp` になります。入れ替えにはAPFSの機能を使うので、`INSTALL_DIR` にはAPFS上のディレクトリを指定します。アプリを入れずに試すなら、`swift build` で作ったリポジトリ内の `.build/debug/polaris-mcp` を絶対パスで指定できます。

## 更新するとき

アプリとMCPは同時に更新し、更新したあとはMCPクライアントも再起動してください。今の版は状態ファイルを最初の読み書きでschemaVersion 2に移し、以前の版はschemaVersion 2を読めません。起動したままの古いpolaris-mcpは、書き換わった状態に `unsupportedSchema` のエラーを返します。

移行のときは、以前の版が和暦や仏暦で書いた日付のキーをグレゴリオ暦に直します。v1には元号が残っていないので、和暦は移行した時点の元号として読みます。読めなかったキーは消さずに残します。

## データの保存先

状態は `~/.polaris/state.json` に保存します。`POLARIS_HOME` にディレクトリの絶対パスを指定すると保存先を切り替えられます。保存先にはシンボリックリンクも使えます。リンクを解決した先は自分が所有するディレクトリで、グループとその他のユーザーが書き込めない必要があります。アプリとMCPを同じ状態につなぐ場合は同じ保存先を指定してください。

state.json が壊れて読めないときは、メニューバーの「状態を作り直す」で `state.corrupt-<日時>-<UUID>.json` に退避して新しく始められます。UUID付きの退避ファイルは新しいものから5件だけ残します。以前の版が作った `state.corrupt-<日時>.json` は消しません。

## プライバシー

Polarisはネットワークに接続しません。データは `~/.polaris/state.json` か `POLARIS_HOME` で指定したディレクトリにだけ保存し、外部へは送りません。前面のアプリが切り替わると、いまのモードで避けたいアプリかを確かめるためにそのbundle IDを見ます。見たbundle IDはメモリ上で比べるだけで保存しません。ショートカットはCarbonの `RegisterEventHotKey` で登録するので、アクセシビリティ権限は要りません。

## 開発に参加する

Issueやプルリクエストの出し方は [CONTRIBUTING.md](CONTRIBUTING.md) にあります。脆弱性はIssueに書かず、[SECURITY.md](SECURITY.md) の手順で非公開で報告してください。

## ライセンス

MITライセンスです。全文は [LICENSE](LICENSE) にあります。

## 開発者向け

### ビルドの設定

`make build` は `swift build` を実行します。`make test` はSwift Testingのテストを実行し、成功したテストが1件もなければ失敗にします。`Resources/Polaris.icns` を置くとアイコンとして同梱します。`make app` では次の値を環境変数で上書きできます。

| 変数 | 既定値 |
|---|---|
| `SIGNING_IDENTITY` | アドホック署名 |
| `BUNDLE_IDENTIFIER` | `dev.mimo.polaris` |
| `VERSION` | `1.0.0` |
| `BUILD_NUMBER` | `git rev-list --count HEAD` の値。取れなければ `1` |

アプリに同梱したpolaris-mcpはアプリのInfo.plistにあるバージョンを名乗ります。単体でビルドしたpolaris-mcpは、ライブラリのPolarisCoreにある既定値の1.0.0を名乗ります。

`make release` は `make app` のあと `build/Polaris.dmg` を作り、署名・公証・ステープルまで行います。`SIGNING_IDENTITY` にDeveloper ID Applicationの署名IDがないと失敗します。公証にはApp Store Connect APIキーで作ったキーチェーンプロファイルを使います。プロファイル名は `NOTARY_PROFILE` で変えられ、既定は `polaris-notary` です。

```sh
xcrun notarytool store-credentials polaris-notary --key <AuthKey_XXXX.p8> --key-id <Key ID> --issuer <Issuer ID>
SIGNING_IDENTITY="Developer ID Application: <名前> (<Team ID>)" make release
```

`make snapshots` はアプリに `--render-snapshots snapshots/` を渡し、主要な状態をライトとダークでPNGに書き出して終了します。一部の状態はコントラスト強調やモード違いも書き出します。ウィンドウは出しません。すりガラスの背景は描けないので、スナップショットでは不透明の背景色で代用します。

### テストとCI

Command Line Tools単体のSwift 6.3.2では、素の `swift test` がテスト0件で終了する問題を確認しています。`make test` はこの環境を検出し、生成ランナーにも `Testing.framework` の探索パスを渡します。Xcode環境では通常の `swift test` を実行します。

実行ファイルを使ったstdio往復・6プロセスの並行更新は、Python 3がある環境で次のように検証できます。

```sh
python3 scripts/polaris-backend-smoke.py
```

プルリクエストとmainへのpushでは、GitHub ActionsがmacOS上で `swift build` と `make test` とこのスモークテストを実行します。

### 状態ファイルの形式

- JSONの日時はISO 8601、日のキーはローカル時刻の `YYYY-MM-DD` です。状態はschemaVersion 2で保存します。
- `state.lock` をflockでロックし、最新の状態に変更を適用して、一時ファイルからrenameします。実際に状態が変わった書き込みでrevisionが1増えます。初回作成はrevision 1です。
- 日付が進んだ最初の読み書きで前日を履歴に移します。モードは既定に戻り、未達の北極星は控えの先頭に戻ります。朝の支度はモードと北極星の2ステップです。
- 北極星は今日1つに加え、控え（最大20件）と終わったログを持てます。日付が進むと未完了の北極星は履歴に残しつつ控えの先頭へ戻ります。完了するとログへ移り、控えの先頭があれば今日になります。
- bannerはMCPから付箋に一時的に出すメッセージで、1件だけ持ちます。表示は既定5分、最大1440分で、読み書きや監視時に期限切れを除去します。
- state.jsonは8MBまでです。超えたファイルは壊れたJSONや未対応のschemaVersionと同じくエラーにし、既存データを上書きしません。

### MCPサーバーの仕様

polaris-mcpは改行区切りJSON-RPC 2.0のstdioサーバーです。標準出力には応答だけを書きます。バッチ要求には対応しません。[MCPのinitializeとツール応答形式](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/docs/specification/2025-06-18/schema.mdx)を利用し、2024-11-05と2025-06-18をネゴシエートできます。

13個のツールを提供します: `polaris_get_today`, `polaris_set_north_star`, `polaris_list_north_stars`, `polaris_add_north_star`, `polaris_update_north_star`, `polaris_complete_north_star`, `polaris_switch_north_star`, `polaris_remove_north_star`, `polaris_get_north_star_log`, `polaris_set_mode`, `polaris_list_modes`, `polaris_nudge`, `polaris_get_history`。引数の詳細は `tools/list` のinputSchemaで取得できます。

北極星は200字、`polaris_nudge` の text は280字までです。字数は書記素とUnicodeスカラーの両方で数え、どちらかが上限を超えるとエラーにします。`polaris_nudge` で出したbannerには差出人として `MCP: <クライアント名>` を表示します。今日の状態や履歴は、北極星とモードを中心に返します。

### PolarisCoreで状態の変化を受け取る

PolarisCoreはSwift Packageのライブラリとして公開していて、アプリとpolaris-mcpもこれを通して状態を読み書きします。

```swift
import PolarisCore

let store = PolarisStore()
let state = try store.read()
let updated = try store.setNorthStar("読む")

// UIのライフサイクルに合わせて購読Taskをキャンセルしてください。
for await change in store.changes() {
    switch change {
    case .success(let state):
        // MainActor上で画面の状態を更新する
        print(state.revision, state.today.northStar)
    case .failure(let error):
        // 読めないことを表示する。監視は続き、読めるようになると .success が届く
        print(error)
    }
}
```

`changes()` は初期状態と新しいrevisionを `.success` で通知し、遅い購読者には最新1件を保持します。ディレクトリのDispatchSource監視で原子的置換を検知し、1秒間隔の補助タイマーで日付変更とbanner期限も反映します。状態を読めないときは `.failure` を1回通知して監視を続け、次に読めた時点で `.success` を通知します。ストア操作は同期APIなので、大きな履歴を扱う処理はUIのメインスレッド外で行ってください。
