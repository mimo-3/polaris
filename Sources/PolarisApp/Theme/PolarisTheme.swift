import AppKit
import SwiftUI

/// design.md 3章のトークン。値を変えるときは design.md も一緒に直す。
enum PolarisTheme {
    enum Palette {
        static let surface = dynamic(0xF4F5F6, 0x1D1E22)
        /// 設定や控えの窓で、まとまりを1枚に載せる面。
        static let raised = dynamic(0xFFFFFF, 0x26282D)
        static let ink = dynamic(0x1C1E22, 0xF1F1F3)
        static let ink2 = dynamic(0x4B5058, 0xAEB2BA)
        static let hairline = dynamic(NSColor(hex: 0x1C1E22, alpha: 0.10), NSColor(white: 1, alpha: 0.10))
        static let hoverFill = dynamic(NSColor(hex: 0x1C1E22, alpha: 0.06), NSColor(white: 1, alpha: 0.08))
        static let pressFill = dynamic(NSColor(hex: 0x1C1E22, alpha: 0.10), NSColor(white: 1, alpha: 0.12))
        /// 光の点・完了チェック・フォーカスリングだけに使う。文字には使わない。
        static let star = dynamic(0xA36F0C, 0xF0C24E)
        static let danger = Color(nsColor: .systemRed)

        /// `Mode.tint` の文字列から引く。glyph にだけ使う。
        enum Mode {
            static let slate = dynamic(0x3D6186, 0x8FB0D3)
            static let moss = dynamic(0x4A6A3A, 0x9CBB86)
            static let clay = dynamic(0x9A573A, 0xDB9C7C)
            static func tint(_ name: String) -> Color {
                switch name {
                case "moss": moss
                case "clay": clay
                default: slate
                }
            }
        }

        enum HighContrast {
            static let ink2 = dynamic(0x2F333A, 0xD5D8DD)
            static let star = dynamic(0x8A5C00, 0xFFD66E)
            static let border = dynamic(NSColor(hex: 0x1C1E22, alpha: 0.35), NSColor(white: 1, alpha: 0.35))
        }

        static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
            dynamic(NSColor(hex: light), NSColor(hex: dark))
        }
        static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            })
        }
    }

    enum Typography {
        static let sheetTitle = Font.system(size: 17, weight: .semibold)
        static let lead = Font.system(size: 15, weight: .semibold)
        static let taskLead = Font.system(size: 14, weight: .semibold)
        static let task = Font.system(size: 14, weight: .regular)
        static let voice = Font.system(size: 13, weight: .regular)
        static let voiceEmphasis = Font.system(size: 13, weight: .semibold)
        static let button = Font.system(size: 13, weight: .semibold)
        static let meta = Font.system(size: 12, weight: .medium)
        static let northStar = northStarFont()

        /// 北極星の行送り。書体の自然な行高（New York 20pt で 24pt）との差を lineSpacing と上下の余白で埋める。
        static let northStarLineHeight: CGFloat = 27
        static let northStarNaturalLineHeight: CGFloat = {
            let font = northStarNSFont()
            return ceil(font.ascender - font.descender + font.leading)
        }()
        static let northStarLineSpacing = max(0, northStarLineHeight - northStarNaturalLineHeight)
        static let northStarPadding = max(0, (northStarLineHeight - northStarNaturalLineHeight) / 2)
        /// voice は 13/18。system 13pt の自然な行高 16 との差。
        static let voiceLineSpacing: CGFloat = 2

        /// New York にヒラギノ明朝 W6 をカスケードする。system(design: .serif) だけでは和文がゴシックに落ちる。
        static func northStarFont(size: CGFloat = 20) -> Font {
            Font(northStarNSFont(size: size))
        }
        static func northStarNSFont(size: CGFloat = 20) -> NSFont {
            let system = NSFont.systemFont(ofSize: size, weight: .semibold)
            let serif = system.fontDescriptor.withDesign(.serif) ?? system.fontDescriptor
            let desc = serif.addingAttributes([.cascadeList: [NSFontDescriptor(name: "HiraMinProN-W6", size: size)]])
            return NSFont(descriptor: desc, size: size) ?? system
        }
    }

    enum Space {
        static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 20, xxl: CGFloat = 24
    }

    enum Radius {
        static let note: CGFloat = 16, sheet: CGFloat = 18, quickEdit: CGFloat = 14
        static let choice: CGFloat = 10, button: CGFloat = 8, small: CGFloat = 6
    }

    enum Metrics {
        static let noteWidth: CGFloat = 304
        static let sheetWidth: CGFloat = 400
        static let quickEditWidth: CGFloat = 400
        static let screenInset: CGFloat = 16
        static let starDot: CGFloat = 8
        static let starHoverRing: CGFloat = 16
        static let rippleEnd: CGFloat = 28
        static let hitMin: CGFloat = 24
        static let rowHit: CGFloat = 28
        static let rowHeight: CGFloat = 20
        static let laterRow: CGFloat = 32
        static let laterMaxRows = 5
        static let collapsedDayClosedHeight: CGFloat = 44
        static let clickThroughAlpha: CGFloat = 0.72
        static let clickThroughAlphaHighContrast: CGFloat = 0.9
        /// 点8 + 間隔10。本命テキストの開始位置。
        static let taskTextInset: CGFloat = 18
    }

    enum Material {
        static let surfaceOpacity: Double = 0.92
        static let hairlineWidth: CGFloat = 0.5
    }

    enum Motion {
        static let hoverDelay: Double = 0.25
        static let leaveDelay: Double = 0.5

        static func expand(_ reduce: Bool) -> Animation {
            reduce ? .easeOut(duration: 0.15) : .spring(response: 0.32, dampingFraction: 0.9)
        }
        static func expandContent(_ reduce: Bool) -> Animation {
            reduce ? .easeOut(duration: 0.15) : .easeOut(duration: 0.18).delay(0.06)
        }
        static func collapse(_ reduce: Bool) -> Animation? {
            reduce ? nil : .spring(response: 0.28, dampingFraction: 1.0)
        }
        static let checkFill = Animation.easeOut(duration: 0.12)
        static func strike(_ reduce: Bool) -> Animation? { reduce ? nil : .linear(duration: 0.2) }
        static func rowExit(_ reduce: Bool) -> Animation {
            reduce ? .easeOut(duration: 0.15) : .easeIn(duration: 0.22)
        }
        static func promote(_ reduce: Bool) -> Animation? {
            reduce ? nil : .spring(response: 0.4, dampingFraction: 0.9)
        }
        static let rippleDuration: Double = 0.9
        static func voiceSwap(_ reduce: Bool) -> Animation {
            reduce ? .easeOut(duration: 0.15) : .easeOut(duration: 0.2)
        }
        static func count(_ reduce: Bool) -> Animation? { reduce ? nil : .easeOut(duration: 0.2) }
        static func laterDisclose(_ reduce: Bool) -> Animation? {
            reduce ? nil : .spring(response: 0.3, dampingFraction: 0.9)
        }
        static let snapDuration: Double = 0.22
        static var snapTiming: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1) }
        static let visibilityDuration: Double = 0.16
        static func sheetIn(_ reduce: Bool) -> Animation {
            reduce ? .easeOut(duration: 0.15) : .easeOut(duration: 0.25)
        }
        static func sheetStep(_ reduce: Bool) -> Animation {
            reduce ? .easeOut(duration: 0.15) : .easeInOut(duration: 0.22)
        }
        static func allDone(_ reduce: Bool) -> Animation? {
            reduce ? nil : .spring(response: 0.3, dampingFraction: 0.9)
        }
        /// 縮めるときに frame を戻すまでの待ち時間（collapse の spring が収まる長さ）。
        static let shrinkSettle: Double = 0.34
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
