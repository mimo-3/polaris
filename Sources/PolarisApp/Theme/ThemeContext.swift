import AppKit
import SwiftUI

/// アクセシビリティ設定とスナップショット描画の有無。SwiftUI 側の同名環境値は書き換えられないので自前で持つ。
struct ThemeContext: Equatable, Sendable {
    var increaseContrast = false
    var reduceMotion = false
    var reduceTransparency = false
    /// ImageRenderer で描くとき。素材は描けないので surface を不透明にする。
    var snapshot = false

    typealias P = PolarisTheme.Palette
    var ink: Color { P.ink }
    var ink2: Color { increaseContrast ? P.HighContrast.ink2 : P.ink2 }
    var star: Color { increaseContrast ? P.HighContrast.star : P.star }
    var usesMaterial: Bool { !(snapshot || increaseContrast || reduceTransparency) }

    @MainActor static func current() -> ThemeContext {
        let ws = NSWorkspace.shared
        return ThemeContext(increaseContrast: ws.accessibilityDisplayShouldIncreaseContrast,
                            reduceMotion: ws.accessibilityDisplayShouldReduceMotion,
                            reduceTransparency: ws.accessibilityDisplayShouldReduceTransparency)
    }
}

private struct ThemeContextKey: EnvironmentKey {
    static let defaultValue = ThemeContext()
}

extension EnvironmentValues {
    var polaris: ThemeContext {
        get { self[ThemeContextKey.self] }
        set { self[ThemeContextKey.self] = newValue }
    }
}
