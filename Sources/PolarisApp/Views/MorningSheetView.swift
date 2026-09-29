import PolarisCore
import SwiftUI

/// 朝の支度。1画面に1ステップ。⎋ で閉じても、そこまでの選択は保存する。
struct MorningSheetView: View {
    @Environment(NoteModel.self) private var model
    @Environment(\.polaris) private var theme
    var close: () -> Void

    @State var step: Int
    @State private var modeID: String
    @State private var northStar: String
    @State private var selected: [UUID]
    @State private var newDraft = ""
    @State private var writingNew = false
    @State private var forward = true
    @State private var cursor = 0
    @FocusState private var focus: Field?
    @FocusState private var rootFocused: Bool

    private enum Field { case northStar, newTask }
    private typealias S = PolarisTheme.Space

    init(state: AppState, step: Int = 1, selected: [UUID]? = nil, close: @escaping () -> Void) {
        self.close = close
        _step = .init(initialValue: step)
        _modeID = .init(initialValue: state.today.mode.id)
        _northStar = .init(initialValue: state.today.northStar)
        _selected = .init(initialValue: selected ?? state.today.now.map(\.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer().frame(height: S.l)
            Group {
                switch step {
                case 1: modeStep
                case 2: northStarStep
                default: tasksStep
                }
            }
            .id(step)
            .transition(stepTransition)
        }
        .padding(S.xxl)
        .frame(width: PolarisTheme.Metrics.sheetWidth, alignment: .leading)
        .background(PanelBackground(radius: PolarisTheme.Radius.sheet))
        .clipShape(RoundedRectangle(cornerRadius: PolarisTheme.Radius.sheet, style: .continuous))
        .focusable()
        .focusEffectDisabled()
        .focused($rootFocused)
        .onAppear { rootFocused = true }
        .onKeyPress(phases: .down, action: handleKey)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.morning)
    }

    private var stepTransition: AnyTransition {
        if theme.reduceMotion { return .opacity }
        let dx: CGFloat = forward ? 24 : -24
        return .asymmetric(insertion: .opacity.combined(with: .offset(x: dx)),
                           removal: .opacity.combined(with: .offset(x: -dx)))
    }

    private var header: some View {
        HStack {
            Text(Copy.morning)
                .font(PolarisTheme.Typography.button)
                .foregroundStyle(theme.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            MetaText(text: Copy.step(step))
        }
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(PolarisTheme.Typography.sheetTitle)
            .foregroundStyle(theme.ink)
            .lineSpacing(4)
    }

    // MARK: Step 1

    private var modeStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            title(Copy.step1Title)
            Spacer().frame(height: S.m)
            VStack(spacing: S.s) {
                ForEach(Array(Mode.defaults.enumerated()), id: \.element.id) { index, mode in
                    ModeChoice(mode: mode, key: index + 1, selected: mode.id == modeID) { choose(mode) }
                }
            }
            Spacer().frame(height: S.xxl)
            HStack {
                Spacer()
                Button { go(to: 2) } label: { Text("\(Copy.writeNorthStar) ⏎") }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private func choose(_ mode: Mode) {
        modeID = mode.id
        model.setMode(mode.id)
    }

    // MARK: Step 2

    private var yesterday: Day? { model.state.history.last }
    private var canCarryOver: Bool {
        guard let y = yesterday, !y.northStar.isEmpty, y.northStar != northStar else { return false }
        return !y.now.isEmpty // 未達のときだけ
    }

    private var northStarStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            title(Copy.step2Title)
            Spacer().frame(height: S.m)
            PolarisTextField(text: $northStar, prompt: Copy.step2Placeholder, font: PolarisTheme.Typography.northStar,
                             lineSpacing: PolarisTheme.Typography.northStarLineSpacing, axis: .vertical, lines: 1...3,
                             onSubmit: { go(to: 3) })
                .focused($focus, equals: .northStar)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .overlay(RoundedRectangle(cornerRadius: PolarisTheme.Radius.small, style: .continuous)
                    .strokeBorder(focus == .northStar ? theme.star : PolarisTheme.Palette.hairline,
                                  lineWidth: focus == .northStar ? 2 : 1))
                .onAppear { if !theme.snapshot { focus = .northStar } }
            Spacer().frame(height: S.s)
            MetaText(text: Copy.step2Hint)
            if canCarryOver, let y = yesterday {
                Spacer().frame(height: S.s)
                Button(Copy.carryOver) { northStar = y.northStar }
                    .buttonStyle(QuietButtonStyle(height: 24))
                    .padding(.leading, -8)
            }
            Spacer().frame(height: S.xxl)
            HStack {
                Button(Copy.back) { go(to: 1) }
                    .buttonStyle(QuietButtonStyle())
                    .padding(.leading, -8)
                Spacer()
                Button { go(to: 3) } label: {
                    Text("\(northStar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Copy.skipNorthStar : Copy.pickThree) ⏎")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    // MARK: Step 3

    private var candidates: [Item] { model.state.today.now + model.state.later }

    private var tasksStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            title(Copy.step3Title)
            Spacer().frame(height: S.xs)
            MetaText(text: Copy.step3Hint)
            Spacer().frame(height: S.m)
            if candidates.isEmpty {
                Text(Copy.laterEmptyMorning)
                    .font(PolarisTheme.Typography.task)
                    .foregroundStyle(theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer().frame(height: S.s)
            } else {
                PolarisScroll(height: CGFloat(min(candidates.count, 6)) * 36, showsIndicators: candidates.count > 6) {
                    VStack(spacing: 0) {
                        ForEach(Array(candidates.enumerated()), id: \.element.id) { index, task in
                            PickRow(task: task, order: selected.firstIndex(of: task.id),
                                    disabled: selected.count >= 3 && !selected.contains(task.id),
                                    origin: origin(of: task),
                                    focused: cursor == index && rootFocused) { toggle(task.id) }
                        }
                    }
                }
            }
            newTaskRow
            Spacer().frame(height: S.xxl)
            HStack {
                Button(Copy.back) { go(to: 2) }
                    .buttonStyle(QuietButtonStyle())
                    .padding(.leading, -8)
                Spacer()
                Button { finish() } label: { Text("\(Copy.startWith(selected.count)) ⏎") }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .onAppear { if candidates.isEmpty && !theme.snapshot { writingNew = true; focus = .newTask } }
    }

    @ViewBuilder private var newTaskRow: some View {
        if writingNew {
            HStack(spacing: 12) {
                Circle().stroke(theme.ink2, lineWidth: 1).frame(width: 20, height: 20)
                PolarisTextField(text: $newDraft, prompt: Copy.addPlaceholder, font: PolarisTheme.Typography.task,
                                 onSubmit: addNew)
                    .focused($focus, equals: .newTask)
            }
            .frame(height: 36)
        } else {
            Button(Copy.writeNew) { writingNew = true; focus = .newTask }
                .buttonStyle(QuietButtonStyle(height: 36))
                .padding(.leading, -8)
        }
    }

    private func origin(of task: Item) -> String? {
        if task.source.hasPrefix("mcp:") { return Copy.from(Copy.clientName(task.source)) }
        if let y = yesterday, y.now.contains(where: { $0.id == task.id }) { return Copy.fromYesterday }
        return nil
    }

    private func toggle(_ id: UUID) {
        if let i = selected.firstIndex(of: id) { selected.remove(at: i) }
        else if selected.count < 3 { selected.append(id) }
    }

    private func addNew() {
        let title = newDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        newDraft = ""
        model.addTask(title, to: .later, position: 0) { placement in
            if selected.count < 3 { selected.append(placement.task.id) }
        }
    }

    // MARK: 進む・戻る・閉じる

    private func go(to next: Int) {
        if step == 2 { saveNorthStar() }
        forward = next > step
        withAnimation(PolarisTheme.Motion.sheetStep(theme.reduceMotion)) { step = next }
        cursor = 0
        if next != 2 { rootFocused = true }
    }

    private func saveNorthStar() { model.setNorthStar(northStar) }

    private func finish() {
        saveNorthStar()
        model.applyMorning(selected: selected)
        close()
    }

    private func dismiss() {
        if step >= 2 { saveNorthStar() }
        close()
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if press.key == .escape { dismiss(); return .handled }
        if press.key == .leftArrow && press.modifiers.contains(.command) {
            if step > 1 { go(to: step - 1) }
            return .handled
        }
        switch step {
        case 1:
            if let n = Int(press.characters), (1...Mode.defaults.count).contains(n) {
                choose(Mode.defaults[n - 1]); return .handled
            }
            if press.key == .return { go(to: 2); return .handled }
        case 3:
            if focus == .newTask { return .ignored }
            switch press.key {
            case .downArrow: cursor = min(cursor + 1, max(candidates.count - 1, 0)); return .handled
            case .upArrow: cursor = max(cursor - 1, 0); return .handled
            case .space:
                if candidates.indices.contains(cursor) { toggle(candidates[cursor].id) }
                return .handled
            case .return: finish(); return .handled
            default: break
            }
        default: break
        }
        return .ignored
    }
}

/// Step 1 の選択肢。h56 r10。選択中は 1.5pt ink の枠で示し、塗らない。
private struct ModeChoice: View {
    var mode: Mode
    var key: Int
    var selected: Bool
    var action: () -> Void
    @Environment(\.polaris) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PolarisTheme.Radius.choice, style: .continuous)
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(PolarisTheme.Palette.Mode.tint(mode.tint))
                    .frame(width: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.label)
                        .font(PolarisTheme.Typography.lead)
                        .foregroundStyle(theme.ink)
                    MetaText(text: AppNames.avoidSummary(mode.avoidApps))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                MetaText(text: "\(key)")
            }
            .padding(.horizontal, 14)
            .frame(height: 56)
            .contentShape(shape)
            .overlay(shape.strokeBorder(selected ? theme.ink : PolarisTheme.Palette.hairline,
                                        lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint("キー \(key)")
    }
}

/// Step 3 の行。h36。選んだ順の番号をリング ⌀20 に入れ、①だけ star で塗る。
private struct PickRow: View {
    var task: Item
    var order: Int?
    var disabled: Bool
    var origin: String?
    var focused: Bool
    var action: () -> Void
    @Environment(\.polaris) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                badge
                Text(task.title)
                    .font(PolarisTheme.Typography.task)
                    .foregroundStyle(order == nil ? theme.ink2 : theme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if let origin { MetaText(text: origin) }
            }
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .focusRing(focused, radius: PolarisTheme.Radius.small)
        .accessibilityLabel(task.title)
        .accessibilityValue(order.map { "\($0 + 1)番目に選択" } ?? "未選択")
    }

    @ViewBuilder private var badge: some View {
        let size: CGFloat = 20
        ZStack {
            if order == 0 {
                Circle().fill(theme.star)
                Text("1").font(PolarisTheme.Typography.meta).monospacedDigit()
                    .foregroundStyle(PolarisTheme.Palette.surface)
            } else if let order {
                Circle().stroke(theme.ink, lineWidth: 1)
                Text("\(order + 1)").font(PolarisTheme.Typography.meta).monospacedDigit().foregroundStyle(theme.ink)
            } else {
                Circle().stroke(theme.ink2, lineWidth: 1)
            }
        }
        .frame(width: size, height: size)
    }
}
