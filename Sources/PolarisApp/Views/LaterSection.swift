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

    private var header: some View {
        HStack(spacing: 0) {
            Text(count == 0 ? Copy.laterEmpty : Copy.later(count))
                .font(PolarisTheme.Typography.meta)
                .monospacedDigit()
                .foregroundStyle(count == 0 ? theme.ink2 : theme.ink)
                .contentTransition(.numericText(value: Double(count)))
                .animation(PolarisTheme.Motion.count(theme.reduceMotion), value: count)
            if model.laterOpen && model.nowFull && count > 0 {
                MetaText(text: Copy.laterFullSuffix, color: theme.ink)
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

    private var list: some View {
        let rows = model.state.later
        let height = CGFloat(min(rows.count, PolarisTheme.Metrics.laterMaxRows)) * PolarisTheme.Metrics.laterRow
        return PolarisScroll(height: height, showsIndicators: rows.count > PolarisTheme.Metrics.laterMaxRows) {
            LazyVStack(spacing: 0) {
                ForEach(rows) { task in LaterRow(task: task) }
            }
        }
    }
}

private struct LaterRow: View {
    var task: Item
    @Environment(NoteModel.self) private var model
    @Environment(\.polaris) private var theme

    var body: some View {
        HStack(spacing: PolarisTheme.Space.s) {
            Text(task.title)
                .font(PolarisTheme.Typography.task)
                .foregroundStyle(theme.ink2)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Button(Copy.moveToNow) { model.moveToNow(task.id) }
                .buttonStyle(SmallButtonStyle())
                .disabled(model.nowFull)
        }
        .frame(height: PolarisTheme.Metrics.laterRow)
        .contextMenu {
            Button(Copy.moveToNow) { model.moveToNow(task.id) }.disabled(model.nowFull)
            Divider()
            Button(Copy.delete, role: .destructive) { model.delete(task.id) }
        }
    }
}
