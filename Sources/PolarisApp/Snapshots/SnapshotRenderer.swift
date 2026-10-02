import AppKit
import PolarisCore
import SwiftUI

/// `Polaris --render-snapshots <dir>`。主要状態を PNG に書き出して終わる。ウィンドウは出さない。
/// ImageRenderer は素材を描けないので、surface を不透明にした近似で描く。
@MainActor
enum SnapshotRenderer {
    struct Variant: Sendable {
        var name: String
        var dark: Bool
        var contrast: Bool
    }

    nonisolated static let light = Variant(name: "light", dark: false, contrast: false)
    nonisolated static let dark = Variant(name: "dark", dark: true, contrast: false)
    nonisolated static let hcLight = Variant(name: "hc-light", dark: false, contrast: true)
    nonisolated static let hcDark = Variant(name: "hc-dark", dark: true, contrast: true)

    struct Scenario {
        var name: String
        var mode = "work"
        var variants: [Variant] = [light, dark]
        /// モード違いを追加で書き出す。
        var extraModes: [String] = []
        var build: (NoteModel) -> AnyView
        var configure: (NoteModel) -> Void = { _ in }
        var state: (String) -> AppState = { Fixtures.state(mode: $0, northStar: Fixtures.star(for: $0)) }
    }

    static func run(to dir: URL) -> Int32 {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var count = 0
            for scenario in scenarios {
                let modes = [scenario.mode] + scenario.extraModes
                for mode in modes {
                    let variants = mode == scenario.mode ? scenario.variants : [light, dark]
                    for variant in variants {
                        let suffix = mode == scenario.mode ? "" : "-\(mode)"
                        let url = dir.appendingPathComponent("\(scenario.name)\(suffix)-\(variant.name).png")
                        try render(scenario, mode: mode, variant: variant, to: url)
                        count += 1
                    }
                }
            }
            try renderMenuBarIcons(to: dir)
            count += 2
            print("\(count) snapshots → \(dir.path)")
            return 0
        } catch {
            FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
            return 1
        }
    }

    private static func render(_ scenario: Scenario, mode: String, variant: Variant, to url: URL) throws {
        var theme = ThemeContext()
        theme.snapshot = true
        theme.increaseContrast = variant.contrast
        let model = NoteModel(state: scenario.state(mode), store: nil)
        model.theme = theme
        model.dayClosedDate = nil
        // 既定は透過だが、多くの場面は開いた付箋を描くので、透過は場面ごとに入れる。
        model.clickThrough = false
        scenario.configure(model)
        theme = model.theme // configure で Differentiate Without Color などを変えられる

        let backdrop = variant.dark ? Color(nsColor: NSColor(hex: 0x34373D)) : Color(nsColor: NSColor(hex: 0xD3D6DA))
        let content = scenario.build(model)
            .environment(model)
            .environment(\.polaris, theme)
            .padding(32)
            .background(backdrop)
            .environment(\.colorScheme, variant.dark ? .dark : .light)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        var image: CGImage?
        NSAppearance(named: variant.dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            image = renderer.cgImage
        }
        guard let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw PolarisError.invalidState("描画に失敗: \(url.lastPathComponent)")
        }
        try png.write(to: url)
    }

    /// メニューバーのアイコン（テンプレート画像）を、明暗それぞれのメニューバーに近い地で書き出す。
    private static func renderMenuBarIcons(to dir: URL) throws {
        for (name, hidden) in [("menubar-icon", false), ("menubar-icon-hidden", true)] {
            let icon = StatusMenu.icon(hidden: hidden)
            let size = NSSize(width: 88, height: 24)
            let image = NSImage(size: size, flipped: false) { rect in
                for (i, dark) in [false, true].enumerated() {
                    let half = NSRect(x: CGFloat(i) * rect.width / 2, y: 0, width: rect.width / 2, height: rect.height)
                    NSColor(hex: dark ? 0x2A2B2F : 0xE9EAEC).setFill()
                    half.fill()
                    let tinted = NSImage(size: icon.size, flipped: false) { r in
                        icon.draw(in: r)
                        (dark ? NSColor.white : NSColor.black).set()
                        r.fill(using: .sourceAtop)
                        return true
                    }
                    tinted.draw(in: NSRect(x: half.midX - 8, y: half.midY - 8, width: 16, height: 16))
                }
                return true
            }
            // 目で確かめられるよう 4倍で書き出す。
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 4, pixelsHigh: Int(size.height) * 4,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
                throw PolarisError.invalidState("描画に失敗: \(name)")
            }
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            guard let png = rep.representation(using: .png, properties: [:]) else {
                throw PolarisError.invalidState("描画に失敗: \(name)")
            }
            try png.write(to: dir.appendingPathComponent("\(name).png"))
        }
    }

    // MARK: 状態

    private static func card() -> AnyView { AnyView(NoteCard()) }

    static let scenarios: [Scenario] = [
        Scenario(name: "collapsed", variants: [light, dark, hcLight, hcDark], extraModes: ["reading", "rest"],
                 build: { _ in card() },
                 state: { Fixtures.state(mode: $0, northStar: $0 == "work" ? Fixtures.shortStar : Fixtures.star(for: $0)) }),
        Scenario(name: "collapsed-2line", build: { _ in card() }),
        Scenario(name: "expanded", variants: [light, dark, hcLight, hcDark], build: { _ in card() }, configure: { m in
            m.pinned = true
            m.hoveredRow = m.today.now.first?.id
        }),
        Scenario(name: "later-open", build: { _ in card() }, configure: { m in
            m.pinned = true
            m.laterOpen = true
        }),
        Scenario(name: "empty-northstar", build: { _ in card() },
                 state: { _ in Fixtures.state(northStar: "", now: [], done: []) }),
        Scenario(name: "empty-now", build: { _ in card() },
                 state: { _ in Fixtures.state(now: [], done: []) }),
        Scenario(name: "empty-northstar-with-now", build: { _ in card() },
                 state: { _ in Fixtures.state(northStar: "") }),
        Scenario(name: "collapsed-dwc", build: { _ in card() }, configure: { m in
            m.theme.differentiateWithoutColor = true
        }),
        Scenario(name: "later-empty", build: { _ in card() }, configure: { m in m.pinned = true },
                 state: { _ in Fixtures.state(later: []) }),
        Scenario(name: "later-keyboard", build: { _ in card() }, configure: { m in
            m.pinned = true
            m.laterOpen = true
            m.isKey = true
            m.keyboardIndex = m.focusOrder.firstIndex(of: .laterRow(Fixtures.later[1].id))
        }, state: { _ in Fixtures.state(now: Array(Fixtures.work.prefix(2))) }),
        Scenario(name: "morning-1", variants: [light, dark, hcLight, hcDark], build: { m in
            AnyView(MorningSheetView(state: m.state, step: 1, close: {}))
        }, state: { _ in Fixtures.state(northStar: "", now: [], done: [], history: [Fixtures.yesterday]) }),
        Scenario(name: "morning-2", build: { m in
            AnyView(MorningSheetView(state: m.state, step: 2, close: {}))
        }, state: { _ in Fixtures.state(northStar: "", now: [], done: [], history: [Fixtures.yesterday]) }),
        Scenario(name: "morning-2-filled", build: { m in
            AnyView(MorningSheetView(state: m.state, step: 2, close: {}))
        }, state: { _ in Fixtures.state(northStar: Fixtures.shortStar, now: [], done: [], history: [Fixtures.yesterday]) }),
        Scenario(name: "morning-3", build: { m in
            AnyView(MorningSheetView(state: m.state, step: 3, selected: [Fixtures.work[0].id, Fixtures.later[1].id], close: {}))
        }, state: { _ in
            Fixtures.state(northStar: Fixtures.longStar, now: [], done: [],
                           later: [Fixtures.work[0]] + Fixtures.later, history: [Fixtures.yesterday])
        }),
        Scenario(name: "completing", build: { _ in card() }, configure: { m in
            m.pinned = true
            m.completing = m.today.now.first?.id
            m.completionPhase = 2
        }),
        Scenario(name: "detour", mode: "reading", variants: [light, dark, hcLight, hcDark], extraModes: ["rest"],
                 build: { _ in card() }, configure: { m in
            m.detour = Detour(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", pid: 0, mode: m.mode)
            m.snapshotRipple = 0.45
        }),
        Scenario(name: "detour-keyboard", mode: "reading", build: { _ in card() }, configure: { m in
            m.detour = Detour(bundleID: "com.anthropic.claudefordesktop", appName: "Claude", pid: 0, mode: m.mode)
            m.isKey = true
            m.keyboardIndex = m.initialKeyboardIndex
        }),
        Scenario(name: "detour-hidden", mode: "reading", build: { _ in AnyView(MiniDetourView()) }, configure: { m in
            m.detour = Detour(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", pid: 0, mode: m.mode)
        }),
        Scenario(name: "banner", build: { _ in card() }, state: { _ in
            Fixtures.state(northStar: Fixtures.shortStar,
                           banner: Banner(text: "PR終わったよ、本命に戻ろう", from: "claude-code",
                                          expiresAt: Date().addingTimeInterval(3600)))
        }),
        Scenario(name: "banner-expanded", build: { _ in card() }, configure: { m in m.pinned = true }, state: { _ in
            Fixtures.state(northStar: Fixtures.shortStar,
                           banner: Banner(text: "PR #128 のレビューが通った。マージは任せて、本命のレビュー指摘に戻ろう",
                                          from: "claude-code", expiresAt: Date().addingTimeInterval(3600)))
        }),
        // banner 表示中にモードを替えた直後。apply を通して、知らせが出る経路ごと確かめる。
        Scenario(name: "banner-mode-changed", build: { _ in card() }, configure: { m in
            var next = m.state
            next.today.mode = Fixtures.mode("reading")
            next.revision += 1
            m.apply(next)
        }, state: { _ in
            Fixtures.state(northStar: Fixtures.shortStar,
                           banner: Banner(text: "PR終わったよ、本命に戻ろう", from: "claude-code",
                                          expiresAt: Date().addingTimeInterval(3600)))
        }),
        // 透過中の付箋と、画面中央側の縁の内側に重ねるつまみ。
        Scenario(name: "clickthrough", build: { m in
            AnyView(NoteCard().overlay(alignment: .leading) {
                HandleGrip(hovered: false, theme: m.theme).padding(.leading, PolarisTheme.Metrics.handleInset)
            })
        }, configure: { m in m.clickThrough = true }),
        Scenario(name: "clickthrough-hover", build: { m in
            AnyView(HStack(spacing: 6) {
                HintBubble(text: Copy.handleHelpClosed)
                NoteCard().overlay(alignment: .leading) {
                    HandleGrip(hovered: true, theme: m.theme).padding(.leading, PolarisTheme.Metrics.handleInset)
                }
            })
        }, configure: { m in m.clickThrough = true }),
        // ホバーの案内。歯車の上に止まったところ。
        Scenario(name: "hint-settings", build: { _ in
            AnyView(NoteCard().overlay { NoteHintOverlay() }.coordinateSpace(name: NoteCard.space))
        }, configure: { m in
            m.pinned = true
            m.hint = NoteHint(text: Hint.settings, frame: CGRect(x: 268, y: 290, width: 20, height: 20))
        }),
        Scenario(name: "overflow-to-later", build: { _ in card() }, configure: { m in
            m.transient = .overflow(taskID: Fixtures.later[0].id, title: "議事録を整える", client: nil)
        }),
        Scenario(name: "overflow-mcp", build: { _ in card() }, configure: { m in
            m.transient = .overflow(taskID: Fixtures.later[1].id, title: "オンボーディング資料の図を差し替える",
                                    client: "Claude Code")
        }),
        // MCP が4件目を足して溢れた記録を受け取ったとき（lastOverflow 経由）。
        Scenario(name: "overflow-mcp-live", build: { _ in card() }, configure: { m in
            var next = m.state
            next.lastOverflow = OverflowEvent(taskID: Fixtures.later[1].id, title: Fixtures.later[1].title,
                                              source: "mcp:claude-code", at: Date())
            next.revision += 1
            m.apply(next)
        }),
        Scenario(name: "overflow-swap", build: { _ in card() }, configure: { m in
            m.transient = .overflow(taskID: Fixtures.later[0].id, title: "議事録を整える", client: nil)
            m.swapping = Fixtures.later[0].id
            m.pinned = true
        }),
        Scenario(name: "undo", build: { _ in card() }, configure: { m in
            m.transient = .undo(taskID: Fixtures.done[1].id, index: 0, title: "PRをマージ", next: nil)
        }),
        Scenario(name: "undo-long", build: { _ in card() }, configure: { m in
            m.transient = .undo(taskID: Fixtures.done[1].id, index: 0,
                                title: "決済APIのリトライ設定を本番の値に合わせて見直す", next: nil)
        }),
        Scenario(name: "all-done", build: { _ in card() },
                 state: { _ in Fixtures.state(now: [], done: Fixtures.done + [Fixtures.completed(Fixtures.task(22, "レビュー指摘を直す"))]) }),
        Scenario(name: "all-done-expanded", build: { _ in card() },
                 configure: { m in m.pinned = true },
                 state: { _ in Fixtures.state(now: [], done: Fixtures.done + [Fixtures.completed(Fixtures.task(22, "レビュー指摘を直す"))]) }),
        Scenario(name: "day-closed", build: { _ in card() }, configure: { m in m.dayClosedDate = Fixtures.date },
                 state: { _ in Fixtures.state(now: [], done: Fixtures.done) }),
        Scenario(name: "settings", build: { _ in
            AnyView(SettingsView(conflicts: [.toggleClickThrough]).background(PolarisTheme.Palette.surface))
        }),
        Scenario(name: "settings-reading", build: { _ in
            AnyView(SettingsView(conflicts: [], initialModeID: "reading").background(PolarisTheme.Palette.surface))
        }),
        Scenario(name: "settings-custom", build: { _ in
            AnyView(SettingsView(conflicts: [], initialModeID: "mode-deep").background(PolarisTheme.Palette.surface))
        }, state: { _ in
            var state = Fixtures.state(mode: "reading")
            let deep = Mode(id: "mode-deep", label: "集中の日", symbol: "circle", tint: "slate",
                            avoidApps: ["com.tinyspeck.slackmacgap"])
            state.modes = [Fixtures.mode("work"), Fixtures.mode("reading"), deep]
            return state
        }),
        Scenario(name: "quick-edit", build: { m in
            AnyView(QuickEditView(state: m.state, focus: .add, close: {}))
        }, state: { _ in Fixtures.state(now: Array(Fixtures.work.prefix(2))) }),
        Scenario(name: "expanded-star-queue", build: { _ in card() }, configure: { m in
            m.pinned = true
        }, state: { _ in Fixtures.withStars(Fixtures.state()) }),
        Scenario(name: "star-achieved", build: { _ in card() }, configure: { m in
            m.transient = .starEnded(starID: Fixtures.starID(9), title: Fixtures.longStar,
                                     next: Fixtures.queuedStars[0].text, achieved: true)
        }, state: { _ in Fixtures.withStars(Fixtures.state(northStar: Fixtures.queuedStars[0].text), promoted: true) }),
        Scenario(name: "stars-window", build: { _ in AnyView(StarsView()) },
                 state: { _ in Fixtures.withStars(Fixtures.state()) }),
        Scenario(name: "celebration-early", variants: [light], build: { _ in celebration(at: 0.25) }),
        Scenario(name: "celebration-mid", variants: [light], build: { _ in celebration(at: 0.8) }),
    ]

    /// 達成の演出のある瞬間。付箋を置いた位置から弾ける。
    private static func celebration(at t: Double) -> AnyView {
        AnyView(ZStack(alignment: .top) {
            Color(white: 0.85)
            card().padding(.top, 360)
            ConfettiBurst(origin: CGPoint(x: 380, y: 396), start: Date().addingTimeInterval(-t))
        }
        .frame(width: 760, height: 640))
    }
}
