# Polaris デザイン仕様「一点の光」

前提: [product.md](product.md)。今日の北極星を1つだけ見せる。文言は `Sources/PolarisApp/Model/Copy.swift`、見た目は既存のデザイントークンに集約する。

## 1. コンセプト

- 無彩色の付箋に、明朝の大きな1文を置く。常駐時の主役は北極星だけ。
- 補足と操作は開いたときに出す。寄り道・MCP の一時メッセージ・北極星の達成や予約の知らせは声の行に出す。
- 用語は「北極星」「控え」「これまで」。窓と入口は「北極星の一覧」に統一する。
- 背景の素材感、ライト／ダーク、Increase Contrast、Reduce Motion を保つ。

## 2. 状態ごとのレイアウト

### 常駐

幅304pt、左右20pt、上下16pt、角丸16pt。北極星は最大2行。達成ボタンと一覧の行は出さない。北極星が空なら「北極星を設定する」だけを入口にする。
期限は展開中、または期限を過ぎているときに北極星の下へ出す。通常のモード表示は開いたときだけ。

### 展開

```
決済APIの移行を今日中に        [✓]
本番へ出す
あと4日
☷ 北極星の一覧  次 〇〇 ほか 2 › [+]
▣ 仕事の日                      ⚙
```

- 1段目は上揃えの HStack。左の北極星は伸縮し最大4行、右の ✓ は `SmallButtonStyle(outlined: true)`、読み上げは「達成した」、案内は `Hint.starAchieve`。今日が空で控えがあるときは「これにする」。閉じた付箋には出さない。
- 北極星の期限の下に8pt空け、一覧の入口を常設する。左のボタン全体で一覧を開く。`list.bullet`＋「北極星の一覧」＋控えがあれば `MetaText` の「次 〇〇 ほか n」＋`chevron.right`。補足が長ければ末尾を省略する。右端の＋は別のボタンで控えへの入力欄を開く。
- 控えが空でも一覧の行は出す。控えが20件なら＋は出さない。入力中も一覧への入口を残す。
- 下段にモードの切り替えと歯車を置く。声の優先順位は寄り道→一時的な知らせ→banner→モード。
- 今日の北極星はクリックで一覧、ダブルクリックでその場の編集。右クリックと VoiceOver から達成・手放すにも届く。

### 朝の支度

幅400pt、余白24pt。モード→北極星の2ステップ。進捗は「1 / 2」「2 / 2」。

1. 「今日はどんな日？」。モードを縦に並べ、数字キーまたは上下キーで選ぶ。「北極星を書く」で進む。
2. 「今日いちばん大事なことを1文で」。明朝の入力欄、補足「1文で書けないなら、まだ絞れていない。」、未達なら昨日の北極星を引き継ぐ入口。「この北極星で始める」で保存して閉じる。空なら主ボタンを無効にし「北極星なしで進む」を出す。

⌘←で戻る。⎋は入力済みの北極星を保存して閉じる。

### クイック編集

⌃⌥Pで北極星だけの入力欄を開く。幅400pt、入力欄はr6、hairline 1pt、フォーカス枠2pt。
⏎で保存、⌥⏎で今日を変えず控えへ入れる、⎋で閉じる。控えが満杯なら入力を残す。

### 北極星の一覧

窓のタイトルは「北極星の一覧」。今日の北極星、控え、これまでを扱う。控えはドラッグで並べ替え、これにする・削除・期限・予約を設定できる。VoiceOverには上へ・下へ等の操作も出す。これまでには達成／手放した記録と期間を出し、控えに戻せる。最新1件より前はたためる。

### メニューバーと設定

表示／非表示のすぐ次に「北極星の一覧… ⌃⌥L」を置く。北極星の書き換え、朝の支度、モード、隅、設定、終了は残す。
設定は表示・モード・ショートカット・起動・MCPの1画面。既存のショートカット欄にも一覧を開く⌃⌥Lを載せる。

## 3. デザイントークン

すべて `Sources/PolarisApp/Theme/PolarisTheme.swift` の `enum PolarisTheme` に置く。色は `NSColor(name:dynamicProvider:)` でライトとダークを切り替え、`Color(nsColor:)` で使う。Asset Catalog は使わない。

### 3-1. 色 `PolarisTheme.Palette`

| 定数 | Light | 対surface | Dark | 対surface | 用途 |
|---|---|---|---|---|---|
| `surface` | #F4F5F6 | – | #1D1E22 | – | 付箋・シートの地 |
| `ink` | #1C1E22 | 15.29 | #F1F1F3 | 14.76 | 北極星・本文・主ボタンの地 |
| `ink2` | #4B5058 | 7.43 | #AEB2BA | 7.83 | 沈める行・補足。**これより薄い文字色は作らない** |
| `hairline` | ink 10% | – | #FFFFFF 10% | – | 区切り線・パネル内枠 0.5pt |
| `hoverFill` | ink 6% | – | #FFFFFF 8% | – | 行ホバー |
| `pressFill` | ink 10% | – | #FFFFFF 12% | – | 押下 |
| `star` | #A36F0C | 3.98（非テキスト） | #F0C24E | 9.94 | 光の点・完了チェック・フォーカスリングの3か所だけ。文字には使わない |
| `danger` | `NSColor.systemRed` | – | 同 | – | 「削除」と保存失敗だけ |

モードのティント `PolarisTheme.Palette.Mode`（`Mode.tint` の文字列 → 定数。未知の値は `slate`）。**glyph にだけ使う**。地は塗らない。

| `Mode.tint` | 定数 | 既定ラベル | 既定 symbol | Light | 比 | Dark | 比 |
|---|---|---|---|---|---|---|---|
| `"slate"` | `Mode.slate` | 仕事の日 | `briefcase` | #3D6186 | 5.91 | #8FB0D3 | 7.39 |
| `"moss"` | `Mode.moss` | 読書の日 | `book.closed` | #4A6A3A | 5.64 | #9CBB86 | 7.82 |
| `"clay"` | `Mode.clay` | 休む日 | `cup.and.saucer` | #9A573A | 5.06 | #DB9C7C | 7.18 |

同時に見える有彩色は `star` とそのモードのティントの最大2色。

`PolarisTheme.Palette.HighContrast`（Increase Contrast のとき差し替える）:

| 定数 | Light | 比 | Dark | 比 |
|---|---|---|---|---|
| `ink2` | #2F333A | 11.62 | #D5D8DD | 11.65 |
| `star` | #8A5C00 | 5.33 | #FFD66E | 11.97 |
| `border` | ink 35% 1pt | – | #FFFFFF 35% 1pt | – |

### 3-2. タイポグラフィ `PolarisTheme.Typography`

| 定数 | 書体 | サイズ/行送り | ウェイト | 用途 |
|---|---|---|---|---|
| `northStar` | New York → ヒラギノ明朝 ProN | 20 / 27（lineSpacing 7） | Semibold / W6 | 北極星（付箋・入力欄） |
| `sheetTitle` | system | 17 / 24 | .semibold | 支度シートの問い |
| `lead` | system | 15 / 20 | .semibold | 支度の選択肢名 |
| `bodyStrong` | system | 14 / 20 | .semibold | 設定の選択中の行 |
| `body` | system | 14 / 20 | .regular | 一覧・設定・追加入力 |
| `voice` | system | 13 / 18 | .regular | banner |
| `voiceEmphasis` | system | 13 / 18 | .semibold | 寄り道の声かけ、完了メッセージ |
| `button` | system | 13 / 18 | .semibold | ボタン |
| `meta` | system | 12 / 16 | .medium | モード名・件数・from・手順番号・キー表記 |

- system は SF Pro＋ヒラギノ角ゴシック。北極星だけを明朝にして、「自分に宛てた1文」と補足情報を書体の段階で分ける。サイズ比は20/14で1.43倍と控えめにして、書体とウェイトで差を足す
- 明朝は `.cascadeList` で組む。`Font.system(design: .serif)` だけでは和文がゴシックに落ちる

```swift
static func northStarFont(size: CGFloat = 20) -> Font {
    let base = NSFont.systemFont(ofSize: size, weight: .semibold).fontDescriptor.withDesign(.serif)!
    let desc = base.addingAttributes([.cascadeList: [NSFontDescriptor(name: "HiraMinProN-W6", size: size)]])
    return Font(NSFont(descriptor: desc, size: size)!)
}
```

- 12pt 未満の文字は使わない。数字には `.monospacedDigit()` を付ける
- 行の省略は `.truncationMode(.tail)`。北極星は常駐で `lineLimit(2)`、展開で `lineLimit(4)`

### 3-3. 余白 `PolarisTheme.Space`

`xs = 4, s = 8, m = 12, l = 16, xl = 20, xxl = 24`

| 場所 | 値 |
|---|---|
| 付箋 上下 / 左右 | `l` / `xl` |
| シート 余白 / 問い→中身 / 中身→ボタン | `xxl` / `m` / `xxl` |

### 3-4. 角丸 `PolarisTheme.Radius`

| 定数 | 値 | 要素 |
|---|---|---|
| `note` | 16 | 付箋パネル |
| `sheet` | 18 | 朝の支度シート |
| `quickEdit` | 14 | クイック編集パネル |
| `choice` | 10 | 支度の選択肢 |
| `button` | 8 | 主ボタン、行ホバー |
| `small` | 6 | 声の行の小ボタン、入力欄 |

点・リング・番号は円。すべて `.continuous`。

### 3-5. 寸法 `PolarisTheme.Metrics`

| 定数 | 値 |
|---|---|
| `noteWidth` | 304 |
| `sheetWidth` / `quickEditWidth` | 400 / 400 |
| `screenInset` | 16 |
| `hitMin` | 24 |
| `handleWidth` / `handleHeight` / `handleInset` | 14 / 48 / 3 |

### 3-6. 素材・影 `PolarisTheme.Material`

- 下地は `NSVisualEffectView(material: .popover, blendingMode: .behindWindow, state: .active)`。nonactivating パネルは `.followsWindowActiveState` だと常に灰色になるので、`.active` に固定する
- その上に `surface` を **92%** で重ねる（`surfaceOpacity = 0.92`）。壁紙の色がわずかに滲む程度にとどめ、文字のコントラストは地で保つ
- 内側に `hairline` 0.5pt の枠を付ける。角は `maskImage` の9-slice（capInsets = 16）で切る
- 影は `NSPanel.hasShadow = true` のシステム影だけにする。frame を変えたら `invalidateShadow()` を呼ぶ。SwiftUI の `.shadow` は使わない
- Reduce Transparency または Increase Contrast のときは素材を外し、`surface` を100%にする
- `--render-snapshots` は ImageRenderer が素材を描けないので、`surface` 100%で描く

---

## 4. 動きとパネル

- NSPanel（nonactivating、floating、全Space・フルスクリーン）。Dockには出さない。
- スナップした隅を固定し、画面の中心側へ伸縮する。伸ばすときはframeを先に広げ、縮めるときは内容のアニメーション後にframeを縮め、最後に影を更新する。
- ホバー250msで開き、外へ出て500msで閉じる。入力・キーボード操作・ドラッグ中は保つ。クリック透過中はつまみで開く。⌥を押してポインタが内側にある間も透過を解除する。
- 閉じた付箋の地の透明度は0〜80%。文字は薄くしない。Reduce Transparency／Increase Contrastでは素材を外す。
- 達成時は北極星の演出と声で知らせ、取り消せる。Reduce Motionを尊重する。ループ・点滅は使わない。
- 一時的に隠す、15分だけ隠す、隅の記憶と日付変更時の再表示は維持する。

## 5. キーボードとアクセシビリティ

| キー | 動作 |
|---|---|
| ⌃⌥P | 北極星のクイック編集 |
| ⌃⌥L | 北極星の一覧 |
| ⌃⌥O | 付箋を操作する |
| ⌃⌥H | 表示／非表示 |
| ⌃⌥T | クリック透過を切り替える |

付箋のTab／↑↓の順は北極星→達成またはこれにする（ある場合）→一覧→控えに足す（空きがある場合）→声の行のボタン。⏎／Spaceで選択した操作を実行する。達成ボタンのフォーカス名 `.starQueue` と `performStarQueueAction` は維持する。⌘Zで北極星の達成を取り消し、⎋でkeyを外し直前のアプリへ戻す。寄り道中は最初に「アプリを隠す」にフォーカスする。

アイコンだけのボタンにも読み上げラベルとホバー案内を付ける。操作対象は24×24pt以上、本文14pt、補足12pt以上。色だけに意味を持たせず、フォーカスリングを出す。声の行が替わったら1回だけ読み上げる。

## 6. スナップショット

`--render-snapshots <dir>` でライト／ダークの主要状態を書き出す。主要状態はコントラスト強調とモード違いも対象。素材は不透明のsurfaceで代用する。

`collapsed`, `collapsed-2line`, `expanded`, `empty-northstar`, `empty-expanded`, `queue-without-today`, `morning-1`, `morning-2`, `morning-2-filled`, `detour`, `detour-keyboard`, `detour-hidden`, `banner`, `banner-expanded`, `banner-mode-changed`, `clickthrough`, `clickthrough-hover`, `hint-settings`, `quick-edit`, `expanded-star-queue`, `star-queue-add`, `star-achieved`, `stars-window`, `settings`, `settings-reading`, `settings-custom`, `celebration-early`, `celebration-mid`, `menubar-icon(-hidden)`。
