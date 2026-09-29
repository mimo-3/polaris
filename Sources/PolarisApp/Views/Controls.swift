import AppKit
import SwiftUI

// MARK: - 地

/// 素材 → surface 92% → hairline の3層。Increase Contrast では外周に border を足す。
struct PanelBackground: View {
    var radius: CGFloat
    @Environment(\.polaris) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            if theme.usesMaterial {
                MaterialBackdrop(radius: radius)
                shape.fill(PolarisTheme.Palette.surface.opacity(PolarisTheme.Material.surfaceOpacity))
            } else {
                shape.fill(PolarisTheme.Palette.surface)
            }
            if theme.increaseContrast {
                shape.strokeBorder(PolarisTheme.Palette.HighContrast.border, lineWidth: 1)
            } else {
                shape.strokeBorder(PolarisTheme.Palette.hairline, lineWidth: PolarisTheme.Material.hairlineWidth)
            }
        }
    }
}

/// NSVisualEffectView。nonactivating パネルでは followsWindowActiveState だと常に灰色になるので active に固定する。
struct MaterialBackdrop: NSViewRepresentable {
    var radius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.maskImage = .roundedMask(radius: radius)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

extension NSImage {
    /// 9-slice で伸びる角丸マスク。角は SwiftUI の .continuous と同じ曲線で切る。
    static func roundedMask(radius: CGFloat) -> NSImage {
        let inset = ceil(radius * 1.6)
        let side = inset * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let path = RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(path)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            return true
        }
        image.capInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        image.resizingMode = .stretch
        return image
    }
}

// MARK: - フォーカスリング

/// star 2pt、要素の外側 2pt。角丸は要素と同じにする。
struct FocusRing: ViewModifier {
    var visible: Bool
    var radius: CGFloat
    @Environment(\.polaris) private var theme

    func body(content: Content) -> some View {
        content.overlay {
            if visible {
                RoundedRectangle(cornerRadius: radius + 3, style: .continuous)
                    .stroke(theme.star, lineWidth: 2)
                    .padding(-3)
                    .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    func focusRing(_ visible: Bool, radius: CGFloat = PolarisTheme.Radius.button) -> some View {
        modifier(FocusRing(visible: visible, radius: radius))
    }
}

// MARK: - ボタン

/// 声の行の小ボタン（h24 r6）。outlined は ink 1pt の枠、そうでなければ文字だけ。
struct SmallButtonStyle: ButtonStyle {
    var outlined = false

    func makeBody(configuration: Configuration) -> some View {
        SmallButtonBody(configuration: configuration, outlined: outlined)
    }
}

/// ButtonStyle 自体では isEnabled が更新されないので、中のビューで読む。
private struct SmallButtonBody: View {
    var configuration: ButtonStyleConfiguration
    var outlined: Bool
    @Environment(\.polaris) private var theme
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PolarisTheme.Radius.small, style: .continuous)
        configuration.label
            .font(PolarisTheme.Typography.button)
            .foregroundStyle(enabled ? theme.ink : theme.ink2)
            .lineLimit(1)
            .padding(.horizontal, outlined ? 10 : 6)
            .frame(minHeight: 24)
            .background(shape.fill(configuration.isPressed ? PolarisTheme.Palette.pressFill : .clear))
            .overlay { if outlined { shape.strokeBorder(enabled ? theme.ink : theme.ink2, lineWidth: 1) } }
            .contentShape(shape)
            .fixedSize()
    }
}

/// シートの主ボタン（h32 r8、地 ink / 文字 surface）。
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PolarisTheme.Typography.button)
            .foregroundStyle(PolarisTheme.Palette.surface)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: PolarisTheme.Radius.button, style: .continuous)
                .fill(PolarisTheme.Palette.ink))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(Rectangle())
    }
}

/// 文字だけのボタン（戻る、リンク）。
struct QuietButtonStyle: ButtonStyle {
    var font: Font = PolarisTheme.Typography.button
    var height: CGFloat = 32
    @Environment(\.polaris) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .foregroundStyle(theme.ink)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(minHeight: height)
            .background(RoundedRectangle(cornerRadius: PolarisTheme.Radius.button, style: .continuous)
                .fill(configuration.isPressed ? PolarisTheme.Palette.pressFill : .clear))
            .contentShape(Rectangle())
    }
}

/// 付箋内のテキストだけのボタン（＋ 追加、本命を追加する など）。押したときだけ塗る。
struct InlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: PolarisTheme.Radius.button, style: .continuous)
                .fill(configuration.isPressed ? PolarisTheme.Palette.pressFill : .clear)
                .padding(.horizontal, -8).padding(.vertical, -4))
    }
}

/// キー表記など、等幅数字の meta。
struct MetaText: View {
    var text: String
    var color: Color? = nil
    @Environment(\.polaris) private var theme

    var body: some View {
        Text(text)
            .font(PolarisTheme.Typography.meta)
            .monospacedDigit()
            .foregroundStyle(color ?? theme.ink2)
    }
}

/// 0.5pt の区切り線。
struct Hairline: View {
    var body: some View {
        Rectangle().fill(PolarisTheme.Palette.hairline).frame(height: PolarisTheme.Material.hairlineWidth)
    }
}
