import PolarisCore
import SwiftUI

/// 今日の北極星と、一覧への入口。
struct NoteCard: View {
    nonisolated static let space = "note"
    @Environment(NoteModel.self) private var model
    @Environment(\.polaris) private var theme
    private typealias S = PolarisTheme.Space

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: S.s) {
                NorthStarView()
                if model.expanded && (model.today.star != nil || !model.state.queuedStars.isEmpty) {
                    StarActionButton()
                }
            }
            if let due = model.today.star?.dueDate.flatMap({ DueDates.starLabel($0, now: model.now) }),
               model.expanded || due.overdue {
                MetaText(text: due.text, color: due.overdue ? PolarisTheme.Palette.danger : nil)
                    .padding(.top, S.xs)
                    .accessibilityLabel("\(Copy.starsDue)、\(due.text)")
            }
            if model.expanded {
                StarQueueLine().padding(.top, S.s)
            }
            if model.expanded || model.voice != .mode {
                VoiceLineView().padding(.top, model.expanded ? S.m : S.l)
            }
        }
        .padding(.vertical, S.l)
        .padding(.horizontal, S.xl)
        .frame(width: PolarisTheme.Metrics.noteWidth, alignment: .leading)
        .background(PanelBackground(radius: PolarisTheme.Radius.note, opacity: model.expanded ? 1 : model.noteOpacity))
        .contentShape(RoundedRectangle(cornerRadius: PolarisTheme.Radius.note, style: .continuous))
        .onTapGesture { model.togglePin() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Polaris。\(model.today.northStar.isEmpty ? Copy.northStarNone : model.today.northStar)。\(model.mode.label)")
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
            } else if model.today.northStar.isEmpty {
                // 空のときは薄い字で誘うだけ。1回押せば書ける。
                Button { model.beginEditing(.northStar) } label: {
                    Text(Copy.northStarEmpty)
                        .font(PolarisTheme.Typography.northStar)
                        // 20pt の大きい字なので、薄くしても 3:1 は保てる。
                        .foregroundStyle(theme.ink2.opacity(theme.increaseContrast ? 1 : 0.75))
                        .padding(.vertical, PolarisTheme.Typography.northStarPadding)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(Copy.northStarEmptyHint)
                .noteHint(Hint.starEmpty)
            } else {
                let text = model.today.northStar
                Text(WordWrap.japanese(text))
                    .font(PolarisTheme.Typography.northStar)
                    .lineSpacing(PolarisTheme.Typography.northStarLineSpacing)
                    .foregroundStyle(theme.ink)
                    .lineLimit(model.expanded ? 4 : 2)
                    .truncationMode(.tail)
                    .padding(.vertical, PolarisTheme.Typography.northStarPadding)
                    .fixedSize(horizontal: false, vertical: true)
                    // 1回押すと北極星の窓（期限・予約・控え）を開き、2回で書き直す。
                    .gesture(TapGesture(count: 2).onEnded { model.beginEditing(.northStar) }
                        .exclusively(before: TapGesture().onEnded { (NSApp.delegate as? AppCoordinator)?.showStars() }))
                    .noteHint(Hint.star)
                    .accessibilityLabel("北極星、\(text)")
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityAction(named: "編集") { model.beginEditing(.northStar) }
                    .modifier(StarEndActions())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusRing(model.focusedTarget == .northStar, radius: PolarisTheme.Radius.small)
    }
}

/// 北極星を終える操作。右クリックと VoiceOver の両方から届くようにする。
private struct StarEndActions: ViewModifier {
    @Environment(NoteModel.self) private var model

    func body(content: Content) -> some View {
        if model.today.star == nil {
            content
        } else {
            content
                .contextMenu {
                    Button(Copy.starAchieved) { model.endNorthStar() }
                    Button(Copy.starDrop) { model.endNorthStar(achieved: false) }
                }
                .accessibilityAction(named: Copy.starAchieved) { model.endNorthStar() }
                .accessibilityAction(named: Copy.starDrop) { model.endNorthStar(achieved: false) }
        }
    }
}

/// 北極星の1行目に上揃えで置く操作。
private struct StarActionButton: View {
    @Environment(NoteModel.self) private var model
    var body: some View {
        Group {
            if model.today.star != nil {
                Button { model.performStarQueueAction() } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 14, height: 16)
                }
                .accessibilityLabel(Copy.starAchieved)
                .noteHint(Hint.starAchieve)
            } else {
                Button(Copy.starUseNext) { model.performStarQueueAction() }
                    .noteHint(Hint.starUseNext)
            }
        }
        .buttonStyle(SmallButtonStyle(outlined: true, focused: model.focusedTarget == .starQueue))
    }
}

/// 控えが空でも常設する一覧への入口。右端の＋は控えへの追加。
struct StarQueueLine: View {
    @Environment(NoteModel.self) private var model
    @Environment(\.polaris) private var theme
    var body: some View {
        HStack(spacing: PolarisTheme.Space.s) {
            Button { (NSApp.delegate as? AppCoordinator)?.showStars() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "list.bullet").accessibilityHidden(true)
                    Text(Copy.starsWindowTitle).fixedSize()
                    if let next = model.state.queuedStars.first {
                        MetaText(text: Copy.starNext(next.text))
                            .lineLimit(1).truncationMode(.tail)
                        if model.state.queuedStars.count > 1 {
                            MetaText(text: Copy.starMore(model.state.queuedStars.count - 1)).fixedSize()
                        }
                    }
                    // 矢印は文字のすぐ後ろに置く。右端の＋と並ぶと、＋の一部に見えるため。
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.ink2)
                        .accessibilityHidden(true)
                    Spacer(minLength: 0)
                }
                .font(PolarisTheme.Typography.meta)
                .foregroundStyle(theme.ink)
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusRing(model.focusedTarget == .starsList)
            .accessibilityHint(Copy.starsOpenHint)
            .noteHint(Hint.starQueue)
            if model.state.queuedStars.count < TextRules.starQueueMax {
                Button { model.beginEditing(.queueStar) } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .bold)).frame(width: 14, height: 16)
                }
                .buttonStyle(SmallButtonStyle(focused: model.focusedTarget == .queueStar))
                .accessibilityLabel(Copy.queueStarAdd)
                .noteHint(Hint.queueStar)
            }
        }
        if model.editing == .queueStar { QueueStarField() }
    }
}

/// 付箋の「＋」から控えに北極星を足す入力欄。明朝ではなく本文の字で、続けて足せる。
private struct QueueStarField: View {
    @Environment(NoteModel.self) private var model
    @Environment(\.polaris) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(theme.ink2)
                .accessibilityHidden(true)
            PolarisTextField(text: $model.draft, prompt: Copy.queueStarPlaceholder, font: PolarisTheme.Typography.body,
                             onSubmit: { model.commitEditing() })
                .focused($focused)
                .onAppear { focused = true }
                .onExitCommand { model.endEditing() }
        }
        .frame(minHeight: 24)
    }
}
