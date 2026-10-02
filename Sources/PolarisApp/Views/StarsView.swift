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
    /// ドラッグ中は手元の並びで動かし、落としたときに1回だけ保存する。
    @State private var draggingID: UUID?
    @State private var order: [UUID]?
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
        .onChange(of: model.state.queuedStars.map(\.id)) { _, _ in resetDrag() }
        .onDisappear { resetDrag() }
        // ⎋ や窓の外で離したドラッグは、落とした合図が来ない。ボタンが離れていたら手元の並びを捨てる。
        .task(id: draggingID) {
            while draggingID != nil {
                try? await _Concurrency.Task.sleep(for: .milliseconds(300))
                if NSEvent.pressedMouseButtons == 0 { resetDrag() }
            }
        }
    }

    private func resetDrag() {
        order = nil
        draggingID = nil
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
                    Button(Copy.starDrop) { model.endNorthStar(achieved: false) }
                        .buttonStyle(SmallButtonStyle())
                    Button(Copy.starAchieved) { model.endNorthStar() }
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
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(stars.enumerated()), id: \.element.id) { index, star in
                if index > 0 { Hairline() }
                queueRow(star, index: index, count: stars.count)
            }
            if !stars.isEmpty { Hairline() }
            addField(full: stars.count >= TextRules.starQueueMax)
                .padding(.vertical, S.m)
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
                        .font(PolarisTheme.Typography.task)
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
            .onTapGesture {
                withAnimation(PolarisTheme.Motion.laterDisclose(theme.reduceMotion)) {
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
        .opacity(draggingID == star.id ? 0.4 : 1)
        .onHover { inside in
            if inside {
                // ドラッグ中はホバーが来ない。来たらドラッグは窓の外で終わっているので、手元の並びを捨てる。
                if draggingID != nil { draggingID = nil; order = nil }
                hovered = star.id
            } else if hovered == star.id {
                hovered = nil
            }
        }
        .modifier(DragReorder(enabled: !theme.snapshot, provide: {
            draggingID = star.id
            return NSItemProvider(object: star.id.uuidString as NSString)
        }, delegate: StarDropDelegate(target: star.id, draggingID: $draggingID, order: $order,
                                      queue: model.state.queuedStars.map(\.id),
                                      reduceMotion: theme.reduceMotion) { id, position in
            // 保存に失敗しても手元の並びを残さない。成功したときは新しい並びが先に届いている。
            model.moveQueuedNorthStar(id, to: position) { order = nil }
        }))
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
            PolarisTextField(text: $draft, prompt: Copy.starsQueuePlaceholder, font: PolarisTheme.Typography.task,
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
                        withAnimation(PolarisTheme.Motion.laterDisclose(theme.reduceMotion)) { logOpen.toggle() }
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
                    .font(PolarisTheme.Typography.task)
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

/// ドラッグで控えを並べ替える。重なった行の位置へ手元の並びを動かし、落としたら保存する。
private struct StarDropDelegate: DropDelegate {
    var target: UUID
    @Binding var draggingID: UUID?
    @Binding var order: [UUID]?
    var queue: [UUID]
    var reduceMotion: Bool
    var commit: (UUID, Int) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingID, dragging != target else { return }
        var ids = order ?? queue
        guard let from = ids.firstIndex(of: dragging), let to = ids.firstIndex(of: target) else { return }
        ids.remove(at: from)
        ids.insert(dragging, at: to)
        withAnimation(PolarisTheme.Motion.promote(reduceMotion)) { order = ids }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        defer { draggingID = nil }
        guard let dragging = draggingID, let ids = order, let position = ids.firstIndex(of: dragging) else {
            order = nil
            return false
        }
        if position != queue.firstIndex(of: dragging) { commit(dragging, position) } else { order = nil }
        return true
    }
}

/// ドラッグの出し手と受け手。ImageRenderer は onDrag の付いた行を描けないので、スナップショットでは付けない。
private struct DragReorder: ViewModifier {
    var enabled: Bool
    var provide: () -> NSItemProvider
    var delegate: StarDropDelegate

    func body(content: Content) -> some View {
        if enabled {
            content.onDrag(provide).onDrop(of: [.text], delegate: delegate)
        } else {
            content
        }
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
