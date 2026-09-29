import PolarisCore
import SwiftUI

/// 付箋そのもの。縦は [北極星] → 12 → [本命] → 16 → [声の行] の3段。
struct NoteCard: View {
    nonisolated static let space = "note"
    @Environment(NoteModel.self) private var model
    @Environment(\.polaris) private var theme
    @Namespace private var starSpace

    private typealias S = PolarisTheme.Space

    var body: some View {
        Group {
            if model.isDayClosed {
                ModeLine(showCounts: false, closed: true)
                    .padding(.horizontal, S.xl)
                    .frame(height: PolarisTheme.Metrics.collapsedDayClosedHeight)
            } else {
                content
                    .padding(.vertical, S.l)
                    .padding(.horizontal, S.xl)
            }
        }
        .frame(width: PolarisTheme.Metrics.noteWidth, alignment: .leading)
        .background(PanelBackground(radius: PolarisTheme.Radius.note))
        .contentShape(RoundedRectangle(cornerRadius: PolarisTheme.Radius.note, style: .continuous))
        .onTapGesture { if !model.isDayClosed { model.togglePin() } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(panelLabel)
    }

    private var panelLabel: String {
        let star = model.today.northStar.isEmpty ? "北極星はまだない" : "北極星、\(model.today.northStar)"
        let lead = model.lead.map { "本命、\($0.title)。" } ?? ""
        return "Polaris。\(star)。\(lead)\(model.mode.label)"
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            NorthStarView()
            Spacer().frame(height: S.m)
            leadBlock
            if model.expanded {
                expandedExtras
                    .transition(.opacity.animation(PolarisTheme.Motion.expandContent(theme.reduceMotion)))
            }
            Spacer().frame(height: model.expanded ? S.m : S.l)
            VoiceLineView()
        }
    }

    // MARK: 2段目

    @ViewBuilder private var leadBlock: some View {
        let today = model.today
        if today.now.isEmpty {
            if !today.done.isEmpty {
                AllDoneRow()
            } else if today.northStar.isEmpty {
                LeadButton(title: Copy.startMorning) { model.requestMorning() }
            } else {
                LeadButton(title: Copy.addLead) { model.beginEditing(.add) }
            }
        } else {
            let rows = model.expanded ? Array(today.now.enumerated()) : [(0, today.now[0])]
            VStack(alignment: .leading, spacing: S.s) {
                ForEach(rows, id: \.1.id) { index, task in
                    TaskRow(task: task, index: index, namespace: starSpace)
                        .transition(rowTransition)
                }
            }
        }
    }

    private var rowTransition: AnyTransition {
        if theme.reduceMotion { return .opacity }
        return .asymmetric(insertion: .opacity.combined(with: .offset(y: 8)),
                           removal: .opacity.combined(with: .offset(y: -8)))
    }

    // MARK: 展開時だけ出るもの

    private var expandedExtras: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: S.m)
            if model.isAllDone && model.editing != .add {
                allDoneActions
            } else {
                AddRow()
            }
            Spacer().frame(height: S.l)
            Hairline()
            Spacer().frame(height: S.m)
            LaterSection()
        }
    }

    private var allDoneActions: some View {
        HStack(spacing: S.s) {
            if model.state.later.isEmpty {
                Button(Copy.add) { model.beginEditing(.add) }
                    .buttonStyle(SmallButtonStyle(outlined: true))
            } else {
                Button(Copy.pickFromLater) {
                    if !model.laterOpen { model.toggleLater() }
                }
                .buttonStyle(SmallButtonStyle(outlined: true))
            }
            Button(Copy.closeDay) { model.closeDay() }
                .buttonStyle(SmallButtonStyle())
        }
    }
}

/// 北極星。明朝 W6 20/27。常駐で2行、展開で4行まで。ダブルクリックでその場で編集する。
struct NorthStarView: View {
    @Environment(NoteModel.self) private var model
    @Environment(\.polaris) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if model.editing == .northStar {
                @Bindable var model = model
                PolarisTextField(text: $model.draft, prompt: Copy.step2Placeholder,
                                 font: PolarisTheme.Typography.northStar,
                                 lineSpacing: PolarisTheme.Typography.northStarLineSpacing,
                                 axis: .vertical, lines: 1...4, onSubmit: { model.commitEditing() })
                    .focused($focused)
                    .onAppear { focused = true }
                    .onExitCommand { model.endEditing() }
            } else {
                let text = model.today.northStar
                Text(text.isEmpty ? Copy.northStarEmpty : text)
                    .font(PolarisTheme.Typography.northStar)
                    .lineSpacing(PolarisTheme.Typography.northStarLineSpacing)
                    .foregroundStyle(theme.ink)
                    .lineLimit(model.expanded ? 4 : 2)
                    .truncationMode(.tail)
                    .padding(.vertical, PolarisTheme.Typography.northStarPadding)
                    .fixedSize(horizontal: false, vertical: true)
                    .onTapGesture(count: 2) { model.beginEditing(.northStar) }
                    .accessibilityLabel(text.isEmpty ? "北極星はまだない" : "北極星、\(text)")
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityAction(named: "編集") { model.beginEditing(.northStar) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusRing(model.focusedTarget == .northStar, radius: PolarisTheme.Radius.small)
    }
}

/// 中空のリング＋taskLead のボタン（朝の支度を始める / 本命を追加する）。まだ光っていない。
private struct LeadButton: View {
    var title: String
    var action: () -> Void
    @Environment(\.polaris) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                StarDot(style: .hollow)
                Text(title)
                    .font(PolarisTheme.Typography.taskLead)
                    .foregroundStyle(theme.ink)
                Spacer(minLength: 0)
            }
            .frame(height: PolarisTheme.Metrics.rowHeight)
        }
        .buttonStyle(InlineButtonStyle())
    }
}

/// いまが空で、済が1件以上。
private struct AllDoneRow: View {
    @Environment(\.polaris) private var theme
    @State private var shown = false

    var body: some View {
        HStack(spacing: 10) {
            StarDot(style: .check)
                .scaleEffect(shown || theme.reduceMotion || theme.snapshot ? 1 : 0.6)
            Text(Copy.allDone)
                .font(PolarisTheme.Typography.taskLead)
                .foregroundStyle(theme.ink)
            Spacer(minLength: 0)
        }
        .frame(height: PolarisTheme.Metrics.rowHeight)
        .onAppear { withAnimation(PolarisTheme.Motion.allDone(theme.reduceMotion)) { shown = true } }
    }
}

/// 「＋ 追加」。押すとその場で入力欄になる。
private struct AddRow: View {
    @Environment(NoteModel.self) private var model
    @Environment(\.polaris) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        if model.editing == .add {
            @Bindable var model = model
            HStack(spacing: 10) {
                StarDot(style: .hollow)
                PolarisTextField(text: $model.draft, prompt: Copy.addPlaceholder, font: PolarisTheme.Typography.task,
                                 onSubmit: { model.commitEditing() })
                    .focused($focused)
                    .onAppear { focused = true }
                    .onExitCommand { model.endEditing() }
            }
            .frame(height: PolarisTheme.Metrics.rowHeight)
        } else {
            Button { model.beginEditing(.add) } label: {
                Text(Copy.add)
                    .font(PolarisTheme.Typography.button)
                    .foregroundStyle(theme.ink2)
                    .frame(height: 18)
            }
            .buttonStyle(InlineButtonStyle())
            .focusRing(model.focusedTarget == .add)
        }
    }
}
