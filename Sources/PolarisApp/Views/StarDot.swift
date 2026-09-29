import SwiftUI

/// 本命の横の光の点と、その変化形。
enum DotStyle: Equatable {
    case lit        // 本命。star の塗り ⌀8
    case hollow     // 2・3件目、まだ光っていないもの。ink2 1pt のリング ⌀8
    case check      // 完了。star の ✓ 10pt semibold
    case litHover   // 本命にホバー。⌀16 のリング付き完了ボタン
    case hollowHover
}

struct StarDot: View {
    var style: DotStyle
    var namespace: Namespace.ID?
    /// 寄り道の波紋。値が変わるたびに1回だけ広がる。
    var rippleToken: Int = 0
    /// スナップショット用。波紋の途中の見た目を固定する。
    var frozenRipple: CGFloat?
    @Environment(\.polaris) private var theme
    @State private var ripple: CGFloat = 1

    private let d = PolarisTheme.Metrics.starDot

    var body: some View {
        ZStack {
            switch style {
            case .lit, .litHover:
                lit
                if style == .litHover {
                    Circle().stroke(theme.star, lineWidth: 1)
                        .frame(width: PolarisTheme.Metrics.starHoverRing, height: PolarisTheme.Metrics.starHoverRing)
                }
            case .hollow:
                Circle().stroke(theme.ink2, lineWidth: 1).frame(width: d, height: d)
            case .hollowHover:
                Circle().stroke(theme.ink2, lineWidth: 1)
                    .frame(width: PolarisTheme.Metrics.starHoverRing, height: PolarisTheme.Metrics.starHoverRing)
            case .check:
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.star)
                    .transition(.opacity)
            }
            rippleRing
        }
        .frame(width: d, height: PolarisTheme.Metrics.rowHeight)
        .overlay(alignment: .trailing) {
            // Differentiate Without Color: 色に頼らず本命を示す。
            if theme.differentiateWithoutColor, style == .lit || style == .litHover {
                Text("▸").font(PolarisTheme.Typography.meta).foregroundStyle(theme.ink)
                    .fixedSize().offset(x: -12)
            }
        }
        .onChange(of: rippleToken) { _, _ in
            guard !theme.reduceMotion else { return }
            ripple = 0
            withAnimation(.easeOut(duration: PolarisTheme.Motion.rippleDuration)) { ripple = 1 }
        }
    }

    @ViewBuilder private var lit: some View {
        let dot = Circle().fill(theme.star).frame(width: d, height: d)
            .overlay { if theme.increaseContrast { Circle().stroke(theme.ink, lineWidth: 1) } }
        if let namespace {
            dot.matchedGeometryEffect(id: "star", in: namespace)
        } else {
            dot
        }
    }

    private var rippleRing: some View {
        let progress = frozenRipple ?? ripple
        let size = d + (PolarisTheme.Metrics.rippleEnd - d) * progress
        return Circle().stroke(theme.star, lineWidth: 1)
            .frame(width: size, height: size)
            .opacity(0.6 * (1 - progress))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
