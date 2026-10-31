import PolarisCore
import SwiftUI
import UniformTypeIdentifiers

/// 北極星の窓。今日 → 控え → これまで の順に、上ほど近い時間を置く。
/// 付箋は今日の1つだけを見せる場所なので、並べ替え・期限・予約・振り返りはこの窓に寄せる。
struct StarsView: View {
    @Environment(NoteModel.self) private var model
    @Environment(\.polaris) private var theme
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool
    @State private var hovered: UUID?
    /// 控えの行のうち、期限と予約の欄を開いている1件。
    @State private var editingID: UUID?
    /// 控えのドラッグ。掴んだ行を指に付けて動かし、ほかの行は落ちる先を空けるようにずらす。離したときに1回だけ保存する。
    @State private var draggingID: UUID?
    @State private var dragY: CGFloat = 0
    /// 保存が返ってくるまで、落とした並びを手元で見せる。
    @State private var order: [UUID]?
    @State private var rowFrames: [UUID: CGRect] = [:]
    /// 掴んでいるあいだだけ true。取り消されて onEnded が来なくても false に戻るので、片付けの合図に使う。
    @GestureState private var pressing = false
    @State private var logOpen = false

    private typealias S = PolarisTheme.Space
    static let width: CGFloat = 480

    var body: some View {
        // ImageRenderer は ScrollView の中身を描かないので、スナップショットでは素の並びにする。
        Group {
            if theme.snapshot { content } else { ScrollView { content } }
        }
        .frame(width: Self.width)
        .background(PolarisTheme.Palette.surface)
        .onChange(of: model.state.queuedStars.map(\.id)) { _, _ in order = nil }
        .onDisappear { resetDrag() }
        .onChange(of: pressing) { _, held in if !held && draggingID != nil { resetDrag() } }
    }

    private func resetDrag() {
        var t = Transaction(animation: nil)
        t.disablesAnimations = true
        withTransaction(t) { draggingID = nil; dragY = 0 }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: S.xxl) {
            GroupCard(title: Copy.starsToday) { today }
            GroupCard(title: Copy.starsQueue, footnote: Copy.starsQueueHelp) { queue }
            GroupCard(title: Copy.starsLog) { log }
        }
        .padding(S.xxl)
    }

    // MARK: 今日

    @ViewBuilder private var today: some View {
        if let star = model.today.star {
            VStack(alignment: .leading, spacing: S.s) {
                Text(WordWrap.japanese(star.text))
                    .font(PolarisTheme.Typography.northStar)
                    .lineSpacing(PolarisTheme.Typography.northStarLineSpacing)
                    .foregroundStyle(theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: S.s) {
                    if let since = star.activatedAt { MetaText(text: StarDates.since(since)) }
                    Spacer(minLength: 0)
                    Button(Copy.starDrop) { model.endNorthStar(id: star.id, achieved: false) }
                        .buttonStyle(SmallButtonStyle())
                    Button(Copy.starAchieved) { model.endNorthStar(id: star.id) }
                        .buttonStyle(SmallButtonStyle(outlined: true))
                }
            }
            .padding(.vertical, S.m)
            Hairline()
            dueRow(star)
        } else {
            MetaText(text: Copy.northStarNone).padding(.vertical, S.m)
        }
    }

    // MARK: 控え

    private var displayedQueue: [NorthStar] {
        let queue = model.state.queuedStars
        guard let order else { return queue }
        return order.compactMap { id in queue.first { $0.id == id } }
    }

    private var queue: some View {
        let stars = displayedQueue
        let target = dropIndex(in: stars)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(stars.enumerated()), id: \.element.id) { index, star in
                VStack(spacing: 0) {
                    if index > 0 { Hairline().opacity(draggingID == star.id ? 0 : 1) }
                    queueRow(star, index: index, count: stars.count)
                }
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(Self.queueSpace)) }) { rowFrames[star.id] = $0 }
                .offset(y: rowOffset(star.id, index: index, in: stars, target: target))
                // ほかの行は落ちる先を空けるように動かす。掴んだ行は指から遅れないよう動かさない。
                .animation(draggingID == star.id ? nil : PolarisTheme.Motion.reorder(theme.reduceMotion), value: target)
                .zIndex(draggingID == star.id ? 1 : 0)
            }
            if !stars.isEmpty { Hairline() }
            addField(full: stars.count >= TextRules.starQueueMax)
                .padding(.vertical, S.m)
        }
        .coordinateSpace(name: Self.queueSpace)
    }

    nonisolated private static let queueSpace = "starQueue"

    /// 掴んだ行の真ん中がどの行の真ん中を越えたかで、落とす位置を決める。
    private func dropIndex(in stars: [NorthStar]) -> Int? {
        guard let id = draggingID else { return nil }
        return dropIndex(of: id, movedBy: dragY, in: stars)
    }

    private func dropIndex(of id: UUID, movedBy offset: CGFloat, in stars: [NorthStar]) -> Int? {
        guard let frame = rowFrames[id] else { return nil }
        let mid = frame.midY + offset
        return stars.filter { $0.id != id }.filter { (rowFrames[$0.id]?.midY ?? .infinity) < mid }.count
    }

    private func rowOffset(_ id: UUID, index: Int, in stars: [NorthStar], target: Int?) -> CGFloat {
        guard let dragging = draggingID, let from = stars.firstIndex(where: { $0.id == dragging }), let target else { return 0 }
        if id == dragging { return dragY }
        let shift = rowFrames[dragging]?.height ?? 0
        if from < target, index > from, index <= target { return -shift }
        if target < from, index >= target, index < from { return shift }
        return 0
    }

    private func dragGesture(_ star: NorthStar, in stars: [NorthStar]) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.queueSpace))
            .updating($pressing) { _, state, _ in state = true }
            .onChanged { value in
                if draggingID == nil {
                    draggingID = star.id
                    editingID = nil
                }
                dragY = value.translation.height
            }
            .onEnded { value in
                // 片付けが先に走って state が消えていても落とせるよう、位置は値から求める。
                let from = stars.firstIndex { $0.id == star.id }
                let to = dropIndex(of: star.id, movedBy: value.translation.height, in: stars)
                if let from, let to, from != to {
                    var ids = stars.map(\.id)
                    ids.remove(at: from)
                    ids.insert(star.id, at: to)
                    var t = Transaction(animation: nil)
                    t.disablesAnimations = true
                    withTransaction(t) { order = ids; draggingID = nil; dragY = 0 }
                    // 保存に失敗しても手元の並びを残さない。成功したときは新しい並びが先に届いている。
                    model.moveQueuedNorthStar(star.id, to: to) { order = nil }
                } else {
                    withAnimation(PolarisTheme.Motion.reorder(theme.reduceMotion)) { draggingID = nil; dragY = 0 }
                }
            }
    }

    private func queueRow(_ star: NorthStar, index: Int, count: Int) -> some View {
        let isHovered = hovered == star.id && draggingID == nil
        let isEditing = editingID == star.id
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: S.s) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.ink2)
                    .frame(width: 12)
                    .opacity(isHovered || draggingID == star.id ? 1 : 0)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(star.text)
                        .font(PolarisTheme.Typography.body)
                        .foregroundStyle(theme.ink)
                        .lineLimit(2)
                        .truncationMode(.tail)
                    starMeta(star)
                }
                .layoutPriority(1)
                Spacer(minLength: 0)
                if isHovered || (theme.snapshot && index == 0) {
                    Button(Copy.starUseNext) { model.activateNorthStar(star.id) }
                        .buttonStyle(SmallButtonStyle(outlined: true))
                    TrashButton(label: Copy.starsDelete(star.text)) { model.removeQueuedNorthStar(star.id) }
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            // 掴めるのは見出しの行だけ。開いた期限・予約の欄を触っても並べ替えは始めない。
            .gesture(dragGesture(star, in: displayedQueue))
            .onTapGesture {
                withAnimation(PolarisTheme.Motion.disclose(theme.reduceMotion)) {
                    editingID = isEditing ? nil : star.id
                }
            }
            if isEditing {
                VStack(alignment: .leading, spacing: 0) {
                    dueRow(star)
                    Hairline()
                    startRow(star)
                }
                .padding(.leading, 20)
                .padding(.bottom, S.xs)
                .transition(.opacity)
            }
        }
        .background {
            // 掴んだ行は面を浮かせ、指に付いていることを見せる。
            if draggingID == star.id {
                RoundedRectangle(cornerRadius: PolarisTheme.Radius.button, style: .continuous)
                    .fill(PolarisTheme.Palette.raised)
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                    .padding(.horizontal, -S.s)
            }
        }
        .onHover { inside in
            if inside { hovered = star.id } else if hovered == star.id { hovered = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityHint(Copy.starsEditHint)
        .accessibilityAction(named: Copy.starUseNext) { model.activateNorthStar(star.id) }
        .accessibilityAction(named: Copy.delete) { model.removeQueuedNorthStar(star.id) }
        .modifier(MoveActions(index: index, count: count) { model.moveQueuedNorthStar(star.id, to: $0) })
    }

    @ViewBuilder private func starMeta(_ star: NorthStar) -> some View {
        let due = star.dueDate.flatMap { DueDates.starLabel($0, now: model.now) }
        if due != nil || star.startsAt != nil {
            HStack(spacing: S.s) {
                if let due {
                    MetaText(text: due.text, color: due.overdue ? PolarisTheme.Palette.danger : nil)
                }
                if let start = star.startsAt {
                    HStack(spacing: 3) {
                        Image(systemName: "alarm")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(theme.ink2)
                            .accessibilityHidden(true)
                        MetaText(text: DueDates.surfaceLabel(start))
                    }
                }
            }
        }
    }

    private func addField(full: Bool) -> some View {
        HStack(spacing: S.s) {
            PolarisTextField(text: $draft, prompt: Copy.starsQueuePlaceholder, font: PolarisTheme.Typography.body,
                             onSubmit: submit)
                .frame(height: 20)
                .focused($fieldFocused)
                .fieldBox(focused: fieldFocused)
                .accessibilityLabel(Copy.starsQueueAdd)
            Button(Copy.starsQueueAdd, action: submit)
                .buttonStyle(SmallButtonStyle(outlined: true))
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || full)
        }
    }

    private func submit() {
        // 満杯のときは ⏎ でも入れない。書いた文は消さずに残す。
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              model.state.queuedStars.count < TextRules.starQueueMax else { return }
        model.queueNorthStar(draft)
        draft = ""
    }

    // MARK: 期限と予約

    private func dueRow(_ star: NorthStar) -> some View {
        let label = star.dueDate.flatMap { DueDates.starLabel($0, now: model.now) }
        return CardRow(title: Copy.starsDue, detail: label?.text ?? Copy.starsDueNone) {
            if let due = star.dueDate, let date = DueDates.pickerDate(due) {
                HStack(spacing: S.xs) {
                    DateField(date: date, components: [.date, .hourAndMinute]) { model.setNorthStarDue(star.id, DueDates.string(dateTime: $0)) }
                        .accessibilityLabel(Copy.starsDue)
                    TrashButton(label: Copy.starsDueClear, symbol: "xmark.circle") { model.setNorthStarDue(star.id, nil) }
                }
            } else {
                Button(Copy.starsDueSet) { model.setNorthStarDue(star.id, DueDates.defaultDue(now: model.now)) }
                    .buttonStyle(SmallButtonStyle())
            }
        }
    }

    private func startRow(_ star: NorthStar) -> some View {
        CardRow(title: Copy.starsStart, detail: Copy.starsStartDetail) {
            if let start = star.startsAt {
                HStack(spacing: S.xs) {
                    DateField(date: start, components: [.date, .hourAndMinute]) { model.setNorthStarStart(star.id, $0) }
                        .accessibilityLabel(Copy.starsStart)
                    TrashButton(label: Copy.starsStartClear, symbol: "xmark.circle") { model.setNorthStarStart(star.id, nil) }
                }
            } else {
                Button(Copy.starsDueSet) { model.setNorthStarStart(star.id, StarDates.nextMorning(after: model.now)) }
                    .buttonStyle(SmallButtonStyle())
            }
        }
    }

    // MARK: これまで

    @ViewBuilder private var log: some View {
        let past = model.state.pastStars.sorted { ($0.endedAt ?? .distantPast) > ($1.endedAt ?? .distantPast) }
        if past.isEmpty {
            MetaText(text: Copy.starsLogEmpty).padding(.vertical, S.m)
        } else {
            // 2件目からはたたんでおく。振り返りたいときだけ開く。
            let shown = logOpen ? past : Array(past.prefix(1))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, star in
                    if index > 0 { Hairline() }
                    logRow(star)
                }
                if past.count > 1 {
                    Hairline()
                    Button {
                        withAnimation(PolarisTheme.Motion.disclose(theme.reduceMotion)) { logOpen.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(logOpen ? Copy.starsLogLess : Copy.starsLogMore(past.count - 1))
                            Image(systemName: logOpen ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .accessibilityHidden(true)
                        }
                        .font(PolarisTheme.Typography.button)
                        .foregroundStyle(theme.ink2)
                        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(logOpen ? Copy.expandedValue : Copy.collapsedValue)
                }
            }
        }
    }

    private func logRow(_ star: NorthStar) -> some View {
        HStack(alignment: .center, spacing: S.s) {
            Image(systemName: star.outcome == .achieved ? "star.fill" : "circle.dashed")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(star.outcome == .achieved ? PolarisTheme.Palette.star : theme.ink2)
                .frame(width: 14)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(star.text)
                    .font(PolarisTheme.Typography.body)
                    .foregroundStyle(star.outcome == .achieved ? theme.ink : theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                MetaText(text: StarDates.summary(star))
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            Button(Copy.starsReopen) { model.reopenNorthStar(star.id) }
                .buttonStyle(SmallButtonStyle())
                .disabled(model.state.queuedStars.count >= TextRules.starQueueMax)
        }
        .padding(.vertical, S.m)
    }
}


/// 見た目のボタンは出さないが、VoiceOver とキーボードからは1つずつ動かせるようにする。
private struct MoveActions: ViewModifier {
    var index: Int
    var count: Int
    var move: (Int) -> Void

    func body(content: Content) -> some View {
        content
            .accessibilityAction(named: Copy.starsMoveUp) { if index > 0 { move(index - 1) } }
            .accessibilityAction(named: Copy.starsMoveDown) { if index < count - 1 { move(index + 1) } }
    }
}

/// ホバーで出すアイコンだけの削除ボタン。見た目は12pt、当たり判定は24。
struct TrashButton: View {
    var label: String
    var symbol = "trash"
    var action: () -> Void
    @Environment(\.polaris) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? PolarisTheme.Palette.danger : theme.ink2)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// 日付（と時刻）の小さな入力欄。スナップショットでは DatePicker が描かれないので文字で代える。
struct DateField: View {
    var date: Date
    var components: DatePickerComponents
    var onChange: (Date) -> Void
    @Environment(\.polaris) private var theme
    /// 保存が返ってくるまでのあいだ、入力した値に戻らないよう手元で持つ。
    @State private var editing: Date?

    var body: some View {
        if theme.snapshot {
            MetaText(text: components.contains(.hourAndMinute)
                     ? date.formatted(.dateTime.year().month().day().hour().minute())
                     : date.formatted(.dateTime.year().month().day()), color: theme.ink)
        } else {
            DatePicker("", selection: Binding(get: { editing ?? date }, set: { editing = $0; onChange($0) }),
                       displayedComponents: components)
                .datePickerStyle(.field)
                .labelsHidden()
                .fixedSize()
                .onChange(of: date) { _, _ in editing = nil }
        }
    }
}

/// 振り返りの日付表記。「9/28 → 9/30（3日）」のように暦日で数える。
enum StarDates {
    private static let format: Date.FormatStyle = .dateTime.month(.defaultDigits).day()

    static func since(_ date: Date) -> String { "\(date.formatted(format))から" }

    /// 予約を決めるときの最初の候補。翌朝9時。
    static func nextMorning(after now: Date, calendar: Calendar = .current) -> Date {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    static func summary(_ star: NorthStar, calendar: Calendar = .current) -> String {
        let outcome = star.outcome == .achieved ? Copy.starOutcomeAchieved : Copy.starOutcomeDropped
        guard let end = star.endedAt else { return outcome }
        let start = star.activatedAt ?? star.createdAt
        let days = (calendar.dateComponents([.day], from: calendar.startOfDay(for: start),
                                            to: calendar.startOfDay(for: end)).day ?? 0) + 1
        let range = days <= 1 ? end.formatted(format) : "\(start.formatted(format)) → \(end.formatted(format))"
        return "\(outcome) · \(range)（\(max(days, 1))日）"
    }
}
