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
        // 濃さの設定は閉じているときの地だけに効かせる。文字は薄くしない。
        .background(PanelBackground(radius: PolarisTheme.Radius.note, opacity: model.expanded ? 1 : model.noteOpacity))
        .contentShape(RoundedRectangle(cornerRadius: PolarisTheme.Radius.note, style: .continuous))
        .onTapGesture { if !model.isDayClosed { model.togglePin() } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(panelLabel)
        // 開閉の AX 操作は、このコンテナではなくモード表示の行とパネルに付ける。
        // SwiftUI は .contain のコンテナを AX の要素として出さず、ここに付けた操作は届かないため。
    }

    private var panelLabel: String {
        let star = model.today.northStar.isEmpty ? Copy.northStarNone : "北極星、\(model.today.northStar)"
        let lead = model.lead.map { "本命、\($0.title)。" } ?? ""
        return "Polaris。\(star)。\(lead)\(model.mode.label)"
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            NorthStarView()
            // 期限は開いたときだけ。過ぎていたら閉じていても出す（見落とすと困るので）。
            if let due = model.today.star?.dueDate.flatMap({ DueDates.starLabel($0, now: model.now) }),
               model.expanded || due.overdue {
                MetaText(text: due.text, color: due.overdue ? PolarisTheme.Palette.danger : nil)
                    .padding(.top, S.xs)
                    .accessibilityLabel("\(Copy.starsDue)、\(due.text)")
            }
            if model.showsStarQueue {
                Spacer().frame(height: S.s)
                StarQueueLine()
                    .transition(.opacity.animation(PolarisTheme.Motion.expandContent(theme.reduceMotion)))
            }
            if hasLeadBlock {
                Spacer().frame(height: S.m)
                leadBlock
            }
            if model.expanded {
                expandedExtras
                    .transition(.opacity.animation(PolarisTheme.Motion.expandContent(theme.reduceMotion)))
            }
            // 閉じているときは北極星と本命だけ。モード表示は開いたときに出し、寄り道や取り消しなどの声だけは閉じていても出す。
            if model.expanded || model.voice != .mode {
                Spacer().frame(height: model.expanded ? S.m : S.l)
                VoiceLineView()
            }
        }
    }

    // MARK: 2段目

    /// 北極星だけあってタスクが空の日は、2段目を出さない。足すときは展開して「＋ タスクを追加」から。
    private var hasLeadBlock: Bool {
        let today = model.today
        return !today.now.isEmpty || !today.done.isEmpty || today.northStar.isEmpty
    }

    @ViewBuilder private var leadBlock: some View {
        let today = model.today
        if today.now.isEmpty {
            if !today.done.isEmpty {
                AllDoneRow()
            } else if today.northStar.isEmpty {
                LeadButton(title: Copy.startMorning) { model.requestMorning() }
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

    /// 付箋のほうから次を勧めない。強い見た目は「今日はここまで」だけにする。
    /// あとでから選びたいときは、すぐ下の「あとで n ›」から開く。
    private var allDoneActions: some View {
        HStack(spacing: S.s) {
            if model.state.later.isEmpty {
                Button(Copy.add) { model.beginEditing(.add) }
                    .buttonStyle(SmallButtonStyle(focused: model.focusedTarget == .allDoneAction(0)))
            }
            let closeIndex = model.allDoneActionCount - 1
            Button(Copy.closeDay) { model.closeDay() }
                .buttonStyle(SmallButtonStyle(outlined: true, focused: model.focusedTarget == .allDoneAction(closeIndex)))
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

/// 北極星もタスクも空の日の2段目（朝の支度を始める）。リングはタスク専用の記号なので使わず、→ を点と同じ x=0〜8 に置く。
private struct LeadButton: View {
    var title: String
    var action: () -> Void
    @Environment(\.polaris) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.ink)
                .fixedSize()
                .frame(width: PolarisTheme.Metrics.starDot, height: PolarisTheme.Metrics.rowHeight)
                .accessibilityHidden(true)
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
            .noteHint(Hint.addTask)
        }
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

/// 展開中だけ北極星のすぐ下に出す1行。「次に控える　CS成長PJのキックオフ　ほか1　［達成した］」。
/// 常駐中は出さない。主役は北極星1つで、控えは達成したときに1段目へ上がってくれば足りる。
struct StarQueueLine: View {
    @Environment(NoteModel.self) private var model
    @Environment(\.polaris) private var theme

    var body: some View {
        let queue = model.state.queuedStars
        let hasToday = model.today.star != nil
        if model.editing == .queueStar {
            QueueStarField()
        } else {
        HStack(spacing: PolarisTheme.Space.s) {
            if let next = queue.first {
                // 押すと控えと振り返りの窓を開く。並べ替えや過去を見るのはそこで行う。
                Button { (NSApp.delegate as? AppCoordinator)?.showStars() } label: {
                HStack(spacing: 6) {
                    MetaText(text: hasToday ? Copy.starNextLabel : Copy.starQueueHead).fixedSize()
                    Text(next.text)
                        .font(PolarisTheme.Typography.meta)
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if queue.count > 1 { MetaText(text: Copy.starMore(queue.count - 1)).fixedSize() }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.ink2)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .layoutPriority(1)
                .accessibilityElement(children: .combine)
                .accessibilityHint(Copy.starsOpenHint)
                .noteHint(Hint.starQueue)
            } else {
                Button { (NSApp.delegate as? AppCoordinator)?.showStars() } label: {
                    HStack(spacing: 6) {
                        MetaText(text: Copy.starsQueueEmpty)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(theme.ink2)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(Copy.starsOpenHint)
                .noteHint(Hint.starQueue)
            }
            Spacer(minLength: 0)
            if queue.count < TextRules.starQueueMax {
                Button { model.beginEditing(.queueStar) } label: { iconLabel("plus") }
                    .buttonStyle(SmallButtonStyle())
                    .accessibilityLabel(Copy.queueStarAdd)
                    .noteHint(Hint.queueStar)
            }
            // 達成は ✓ の印だけにする。押すと何が起きるかはホバーの案内と読み上げで伝える。
            if hasToday {
                Button { model.performStarQueueAction() } label: { iconLabel("checkmark") }
                    .buttonStyle(SmallButtonStyle(outlined: true, focused: model.focusedTarget == .starQueue))
                    .accessibilityLabel(Copy.starAchieved)
                    .noteHint(Hint.starAchieve)
            } else {
                Button(Copy.starUseNext) { model.performStarQueueAction() }
                    .buttonStyle(SmallButtonStyle(outlined: true, focused: model.focusedTarget == .starQueue))
                    .noteHint(Hint.starUseNext)
            }
        }
        .frame(minHeight: 24)
        }
    }

    private func iconLabel(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .bold))
            .frame(width: 14, height: 16)
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
            PolarisTextField(text: $model.draft, prompt: Copy.queueStarPlaceholder, font: PolarisTheme.Typography.task,
                             onSubmit: { model.commitEditing() })
                .focused($focused)
                .onAppear { focused = true }
                .onExitCommand { model.endEditing() }
        }
        .frame(minHeight: 24)
    }
}
