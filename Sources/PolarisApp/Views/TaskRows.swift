import PolarisCore
import SwiftUI

/// いまの1行。本命は光の点と semibold、2・3件目は ink2 のリングと regular。
struct TaskRow: View {
    var task: Item
    var index: Int
    var namespace: Namespace.ID
    @Environment(NoteModel.self) private var model
    @Environment(\.polaris) private var theme
    @State var dragY: CGFloat = 0
    @FocusState var fieldFocused: Bool

    private var isLead: Bool { index == 0 }
    private var hovered: Bool { model.hoveredRow == task.id && model.expanded }
    private var completing: Bool { model.completing == task.id }
    private var renaming: Bool { model.editing == .rename(task.id) }

    var body: some View {
        HStack(spacing: 10) {
            dot
            title
            Spacer(minLength: 0)
            if model.expanded { trailing }
        }
        .frame(height: PolarisTheme.Metrics.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: PolarisTheme.Radius.button, style: .continuous)
                .fill(hovered && !renaming ? PolarisTheme.Palette.hoverFill : .clear)
                .padding(.horizontal, -8).padding(.vertical, -4)
        }
        .focusRing(model.focusedTarget == .row(task.id))
        .contentShape(Rectangle().inset(by: -4))
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(NoteCard.space)) }) { frame in
            model.rowFrames[task.id] = frame
        }
        .onDisappear { model.rowFrames[task.id] = nil }
        .offset(y: dragY)
        .zIndex(dragY == 0 ? 0 : 1)
        .gesture(reorderGesture, including: model.expanded && !renaming ? .all : .subviews)
        .contextMenu { if !renaming { RowMenuItems(task: task, index: index) } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isLead ? "本命、\(task.title)" : "いまの\(index + 1)件目、\(task.title)")
        .accessibilityValue(completing ? "完了" : "")
        // 点のボタンは combine で行に吸われるので、行そのものの既定操作（AXPress）を完了にする。
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Copy.completeHint)
        .accessibilityAction { model.complete(task.id) }
        .accessibilityAction(named: "完了にする") { model.complete(task.id) }
        .accessibilityAction(named: "あとでに送る") { model.sendLater(task.id) }
        .modifier(LeadAction(isLead: isLead) { model.makeLead(task.id) })
    }

    private var dotStyle: DotStyle {
        if completing && model.completionPhase >= 1 { return .check }
        if isLead { return hovered ? .litHover : .lit }
        return hovered ? .hollowHover : .hollow
    }

    private var dot: some View {
        Button { model.complete(task.id) } label: {
            StarDot(style: dotStyle, namespace: isLead && !completing ? namespace : nil,
                    rippleToken: isLead ? model.rippleToken : 0,
                    frozenRipple: isLead ? model.snapshotRipple : nil)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -8).padding(.vertical, -2)
        .accessibilityLabel("\(task.title)を完了にする")
        .accessibilityValue(completing ? "完了" : "")
    }

    @ViewBuilder private var title: some View {
        if renaming {
            @Bindable var model = model
            PolarisTextField(text: $model.draft, prompt: task.title,
                             font: isLead ? PolarisTheme.Typography.taskLead : PolarisTheme.Typography.task,
                             onSubmit: { model.commitEditing() })
                .focused($fieldFocused)
                .onAppear { fieldFocused = true }
                .onExitCommand { model.endEditing() }
        } else {
            Text(task.title)
                .font(isLead ? PolarisTheme.Typography.taskLead : PolarisTheme.Typography.task)
                .foregroundStyle(isLead && !completing ? theme.ink : theme.ink2)
                .lineLimit(1)
                .truncationMode(.tail)
                .overlay(alignment: .leading) { strike }
                .onTapGesture(count: 2) { if model.expanded { model.beginEditing(.rename(task.id)) } }
        }
    }

    /// 取り消し線を左から右へ描く。
    private var strike: some View {
        Rectangle()
            .fill(theme.ink2)
            .frame(height: 1)
            .scaleEffect(x: completing && model.completionPhase >= 2 ? 1 : 0, anchor: .leading)
            .allowsHitTesting(false)
    }

    @ViewBuilder private var trailing: some View {
        if model.swapping != nil {
            // 本命とは入れ替えない。ラベルは控えめにして、タイトルを削らない。
            if !isLead {
                Button(Copy.swapWithThis) { model.swap(out: task.id) }
                    .buttonStyle(SmallButtonStyle(focused: model.focusedTarget == .swapTarget(task.id),
                                                  quiet: !(hovered || model.focusedTarget == .swapTarget(task.id))))
                    .accessibilityLabel("\(task.title)と入れ替える")
            }
        } else if hovered && !renaming && theme.snapshot {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.ink2)
                .frame(width: PolarisTheme.Metrics.hitMin, height: PolarisTheme.Metrics.rowHeight)
        } else if hovered && !renaming {
            Menu {
                RowMenuItems(task: task, index: index)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.ink2)
                    .frame(width: PolarisTheme.Metrics.hitMin, height: PolarisTheme.Metrics.hitMin)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: PolarisTheme.Metrics.hitMin, height: PolarisTheme.Metrics.rowHeight)
            .accessibilityLabel("\(task.title)の操作")
        }
    }

    private var reorderGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                model.dragging = true
                dragY = value.translation.height
            }
            .onEnded { value in
                let step = PolarisTheme.Metrics.rowHeight + PolarisTheme.Space.s
                let target = min(max(index + Int((value.translation.height / step).rounded()), 0), model.today.now.count - 1)
                withAnimation(PolarisTheme.Motion.promote(theme.reduceMotion)) { dragY = 0 }
                model.dragging = false
                model.reorder(task.id, to: target)
            }
    }
}

/// 行メニュー: 本命にする / あとでに送る / 名前を変える / 削除。
struct RowMenuItems: View {
    var task: Item
    var index: Int
    @Environment(NoteModel.self) private var model

    var body: some View {
        if index > 0 { Button(Copy.makeLead) { model.makeLead(task.id) } }
        Button(Copy.sendLater) { model.sendLater(task.id) }
        Button(Copy.rename) { model.beginEditing(.rename(task.id)) }
        Divider()
        Button(Copy.delete, role: .destructive) { model.delete(task.id) }
    }
}

private struct LeadAction: ViewModifier {
    var isLead: Bool
    var action: () -> Void
    func body(content: Content) -> some View {
        if isLead { content } else { content.accessibilityAction(named: "本命にする", action) }
    }
}
