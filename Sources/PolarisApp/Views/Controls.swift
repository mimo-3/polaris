import AppKit
import SwiftUI

// MARK: - 地

/// 素材 → surface 92% → hairline の3層。Increase Contrast では外周に border を足す。
/// opacity は地だけに掛ける。中の文字まで薄くしないため。
struct PanelBackground: View {
    var radius: CGFloat
    var opacity: Double = 1
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
        .opacity(opacity)
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
/// quiet は ink2 の文字（行の右に出す控えめな操作）。focused はキーボードのフォーカスリング。
struct SmallButtonStyle: ButtonStyle {
    var outlined = false
    var focused = false
    var quiet = false

    func makeBody(configuration: Configuration) -> some View {
        SmallButtonBody(configuration: configuration, outlined: outlined, focused: focused, quiet: quiet)
    }
}

/// ButtonStyle 自体では isEnabled が更新されないので、中のビューで読む。
private struct SmallButtonBody: View {
    var configuration: ButtonStyleConfiguration
    var outlined: Bool
    var focused: Bool
    var quiet: Bool
    @Environment(\.polaris) private var theme
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PolarisTheme.Radius.small, style: .continuous)
        configuration.label
            .font(PolarisTheme.Typography.button)
            .foregroundStyle(enabled && !quiet ? theme.ink : theme.ink2)
            .lineLimit(1)
            .padding(.horizontal, outlined ? 10 : 6)
            .frame(minHeight: 24)
            .background(shape.fill(configuration.isPressed ? PolarisTheme.Palette.pressFill : .clear))
            .overlay { if outlined { shape.strokeBorder(enabled ? theme.ink : theme.ink2, lineWidth: 1) } }
            .contentShape(shape)
            .focusRing(focused, radius: PolarisTheme.Radius.small)
            .fixedSize()
    }
}

/// シートの主ボタン（h32 r8、地 ink / 文字 surface）。無効のときは地を hairline 相当に落とす。
struct PrimaryButtonStyle: ButtonStyle {
    var focused = false

    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration, focused: focused)
    }
}

private struct PrimaryButtonBody: View {
    var configuration: ButtonStyleConfiguration
    var focused: Bool
    @Environment(\.polaris) private var theme
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .font(PolarisTheme.Typography.button)
            .foregroundStyle(enabled ? PolarisTheme.Palette.surface : theme.ink2)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: PolarisTheme.Radius.button, style: .continuous)
                .fill(enabled ? PolarisTheme.Palette.ink : PolarisTheme.Palette.pressFill))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(Rectangle())
            .focusRing(focused, radius: PolarisTheme.Radius.button)
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

/// キーキャップ風の数字（16×16 r4、1pt hairline）。
struct KeyCap: View {
    var text: String
    @Environment(\.polaris) private var theme

    var body: some View {
        Text(text)
            .font(PolarisTheme.Typography.meta)
            .monospacedDigit()
            .foregroundStyle(theme.ink2)
            .frame(width: 16, height: 16)
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(theme.increaseContrast ? PolarisTheme.Palette.HighContrast.border : PolarisTheme.Palette.hairline,
                              lineWidth: 1))
    }
}

/// 入力欄の器（r6、1pt hairline、フォーカス中は star 2pt、内側 8/10）。支度とクイック編集で共通。
struct FieldBox: ViewModifier {
    var focused: Bool
    @Environment(\.polaris) private var theme

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10).padding(.vertical, 8)
            .overlay(RoundedRectangle(cornerRadius: PolarisTheme.Radius.small, style: .continuous)
                .strokeBorder(focused ? theme.star : (theme.increaseContrast ? PolarisTheme.Palette.HighContrast.border
                                                                              : PolarisTheme.Palette.hairline),
                              lineWidth: focused ? 2 : 1))
    }
}

extension View {
    func fieldBox(focused: Bool) -> some View { modifier(FieldBox(focused: focused)) }
}

/// 0.5pt の区切り線。
struct Hairline: View {
    var body: some View {
        Rectangle().fill(PolarisTheme.Palette.hairline).frame(height: PolarisTheme.Material.hairlineWidth)
    }
}

/// 窓の中の1まとまり。見出しを面の外に置き、中身は白い面に載せる。行の区切りは中身の側で Hairline を引く。
struct GroupCard<Content: View>: View {
    var title: String
    var footnote: String? = nil
    @ViewBuilder var content: Content
    @Environment(\.polaris) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: PolarisTheme.Space.s) {
            Text(title)
                .font(PolarisTheme.Typography.button)
                .foregroundStyle(theme.ink)
                .accessibilityAddTraits(.isHeader)
                .padding(.leading, PolarisTheme.Space.xs)
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, PolarisTheme.Space.l)
                .padding(.vertical, PolarisTheme.Space.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: PolarisTheme.Radius.choice, style: .continuous)
                        .fill(PolarisTheme.Palette.raised)
                        .overlay {
                            RoundedRectangle(cornerRadius: PolarisTheme.Radius.choice, style: .continuous)
                                .strokeBorder(PolarisTheme.Palette.hairline)
                        }
                }
            if let footnote {
                MetaText(text: footnote).padding(.leading, PolarisTheme.Space.xs)
            }
        }
    }
}

/// GroupCard の中の1行。左に名前（と補足）、右に操作。
struct CardRow<Trailing: View>: View {
    var title: String
    var detail: String? = nil
    @ViewBuilder var trailing: Trailing
    @Environment(\.polaris) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: PolarisTheme.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(PolarisTheme.Typography.task).foregroundStyle(theme.ink)
                if let detail { MetaText(text: detail) }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.vertical, PolarisTheme.Space.m)
        .frame(minHeight: 44)
    }
}
