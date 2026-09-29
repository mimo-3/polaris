import PolarisCore
import SwiftUI

/// 「あとで n ›」。押すとその場で最大5行のスクロール領域が開く。
struct LaterSection: View {
    @Environment(NoteModel.self) private var model
    @Environment(\.polaris) private var theme

    private var count: Int { model.state.later.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { model.toggleLater() } label: { header }
                .buttonStyle(InlineButtonStyle())
                .disabled(count == 0)
                .focusRing(model.focusedTarget == .later)
                .accessibilityLabel("あとで、\(count)件")
                .accessibilityValue(model.laterOpen ? "開いている" : "閉じている")
                .accessibilityAddTraits(.isButton)
            if model.laterOpen && count > 0 {
                list
                    .padding(.top, PolarisTheme.Space.s)
                    .transition(.opacity)
            }
        }
    }

    /// 付箋の中でいちばん静かな段。見出しは ink2、件数だけ等幅数字。
    private var header: some View {
        HStack(spacing: 0) {
            Text(count == 0 ? Copy.laterEmpty : Copy.later(count))
                .font(PolarisTheme.Typography.meta)
                .monospacedDigit()
                .foregroundStyle(theme.ink2)
                .contentTransition(.numericText(value: Double(count)))
                .animation(PolarisTheme.Motion.count(theme.reduceMotion), value: count)
            if model.laterOpen && model.nowFull && count > 0 {
                MetaText(text: Copy.laterFullSuffix)
            }
            Spacer(minLength: 0)
            if count > 0 {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.ink2)
                    .rotationEffect(.degrees(model.laterOpen ? 90 : 0))
                    .frame(width: PolarisTheme.Metrics.hitMin)
                    .accessibilityHidden(true)
            }
        }
        .frame(height: 16)
    }

    /// いまとは別の棚だと形で分ける: hoverFill の面（r8）に収め、行は 13pt ink2、左に 8pt 字下げ。
    private var list: some View {
        let rows = model.state.later
        let height = CGFloat(min(rows.count, PolarisTheme.Metrics.laterMaxRows)) * PolarisTheme.Metrics.laterRow
        return PolarisScroll(height: height, showsIndicators: rows.count > PolarisTheme.Metrics.laterMaxRows) {
            LazyVStack(spacing: 0) {
                ForEach(rows) { task in LaterRow(task: task) }
            }
            .padding(.horizontal, PolarisTheme.Space.xs)
        }
        .padding(.vertical, PolarisTheme.Space.xs)
        .background(RoundedRectangle(cornerRadius: PolarisTheme.Radius.button, style: .continuous)
            .fill(PolarisTheme.Palette.hoverFill))
    }
}

private struct LaterRow: View {
    var task: Item
    @Environment(NoteModel.self) private var model
    @Environment(\.polaris) private var theme

    private var focused: Bool { model.focusedTarget == .laterRow(task.id) }
    /// 「いまに入れる」はホバー中かフォーカス中の行にだけ出す。満杯なら出さない（見出しの「・いまは満杯」で伝える）。
    private var showsAction: Bool {
        !model.nowFull && (focused || (model.hoveredRow == task.id && model.expanded))
    }

    var body: some View {
        HStack(spacing: PolarisTheme.Space.s) {
            Text(task.title)
                .font(PolarisTheme.Typography.voice)
                .foregroundStyle(theme.ink2)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if showsAction {
                Button(Copy.moveToNow) { model.moveToNow(task.id) }
                    .buttonStyle(SmallButtonStyle())
            }
        }
        .padding(.leading, PolarisTheme.Space.xs)
        .frame(height: PolarisTheme.Metrics.laterRow)
        .contentShape(Rectangle())
        .focusRing(focused, radius: PolarisTheme.Radius.small)
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(NoteCard.space)) }) { frame in
            model.rowFrames[task.id] = frame
        }
        .onDisappear { model.rowFrames[task.id] = nil }
        .contextMenu {
            Button(Copy.moveToNow) { model.moveToNow(task.id) }.disabled(model.nowFull)
            Divider()
            Button(Copy.delete, role: .destructive) { model.delete(task.id) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(task.title)
        .accessibilityAction(named: Copy.moveToNow) { model.moveToNow(task.id) }
    }
}
