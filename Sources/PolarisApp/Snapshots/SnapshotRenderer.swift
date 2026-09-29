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
        scenario.configure(model)

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
        Scenario(name: "morning-1", variants: [light, dark, hcLight, hcDark], build: { m in
            AnyView(MorningSheetView(state: m.state, step: 1, close: {}))
        }, state: { _ in Fixtures.state(northStar: "", now: [], done: [], history: [Fixtures.yesterday]) }),
        Scenario(name: "morning-2", build: { m in
            AnyView(MorningSheetView(state: m.state, step: 2, close: {}))
        }, state: { _ in Fixtures.state(northStar: "", now: [], done: [], history: [Fixtures.yesterday]) }),
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
        Scenario(name: "detour-hidden", mode: "reading", build: { _ in AnyView(MiniDetourView()) }, configure: { m in
            m.detour = Detour(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", pid: 0, mode: m.mode)
        }),
        Scenario(name: "banner", build: { _ in card() }, state: { _ in
            Fixtures.state(northStar: Fixtures.shortStar,
                           banner: Banner(text: "PR終わったよ、本命に戻ろう", from: "claude-code",
                                          expiresAt: Date().addingTimeInterval(3600)))
        }),
        Scenario(name: "clickthrough", build: { m in
            AnyView(NoteCard().opacity(m.theme.clickThroughAlpha))
        }, configure: { m in m.clickThrough = true }),
        Scenario(name: "overflow-to-later", build: { _ in card() }, configure: { m in
            m.transient = .overflow(taskID: Fixtures.later[0].id, title: "議事録を整える", client: nil)
        }),
        Scenario(name: "overflow-swap", build: { _ in card() }, configure: { m in
            m.transient = .overflow(taskID: Fixtures.later[0].id, title: "議事録を整える", client: nil)
            m.swapping = Fixtures.later[0].id
            m.pinned = true
        }),
        Scenario(name: "undo", build: { _ in card() }, configure: { m in
            m.transient = .undo(taskID: Fixtures.done[1].id, index: 0, title: "PRをマージ", next: nil)
        }),
        Scenario(name: "all-done", build: { _ in card() },
                 state: { _ in Fixtures.state(now: [], done: Fixtures.done + [Fixtures.completed(Fixtures.task(22, "レビュー指摘を直す"))]) }),
        Scenario(name: "all-done-expanded", build: { _ in card() },
                 configure: { m in m.pinned = true },
                 state: { _ in Fixtures.state(now: [], done: Fixtures.done + [Fixtures.completed(Fixtures.task(22, "レビュー指摘を直す"))]) }),
        Scenario(name: "day-closed", build: { _ in card() }, configure: { m in m.dayClosedDate = Fixtures.date },
                 state: { _ in Fixtures.state(now: [], done: Fixtures.done) }),
        Scenario(name: "quick-edit", build: { m in
            AnyView(QuickEditView(state: m.state, focus: .add, close: {}))
        }, state: { _ in Fixtures.state(now: Array(Fixtures.work.prefix(2))) }),
    ]
}
