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
    @State private var forward = true
    /// Tab で主ボタンへ移ったとき。
    @State private var onPrimary = false
    @FocusState private var focus: Field?
    @FocusState private var rootFocused: Bool

    private enum Field { case northStar }
    private typealias S = PolarisTheme.Space

    init(state: AppState, step: Int = 1, close: @escaping () -> Void) {
        self.close = close
        _step = .init(initialValue: step)
        _modeID = .init(initialValue: state.today.mode.id)
        _northStar = .init(initialValue: state.today.northStar)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer().frame(height: S.l)
            Group {
                switch step {
                case 1: modeStep
                default: northStarStep
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
                ForEach(Array(model.modes.enumerated()), id: \.element.id) { index, mode in
                    ModeChoice(mode: mode, key: index + 1, selected: mode.id == modeID,
                               focused: mode.id == modeID && keyboardVisible && !onPrimary) { choose(mode) }
                }
            }
            Spacer().frame(height: S.xxl)
            HStack {
                Spacer()
                Button { go(to: 2) } label: { Text("\(Copy.writeNorthStar) ⏎") }
                    .buttonStyle(PrimaryButtonStyle(focused: onPrimary && keyboardVisible))
            }
        }
    }

    /// キーボードのフォーカスを描くか。スナップショットでは開いた直後の位置を描く。
    private var keyboardVisible: Bool { rootFocused || theme.snapshot }

    private func choose(_ mode: Mode) {
        modeID = mode.id
        model.setMode(mode.id)
    }

    // MARK: Step 2

    private var yesterday: Day? { model.state.history.last }
    private var canCarryOver: Bool {
        guard let y = yesterday, !y.northStar.isEmpty, y.northStar != northStar else { return false }
        // 未達のときだけ。終えていない北極星は日付が替わると控えへ戻るので、控えに残っているかで見る。
        guard let star = y.star else { return false }
        return model.state.queuedStars.contains { $0.id == star.id }
    }

    private var northStarStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            title(Copy.step2Title)
            Spacer().frame(height: S.m)
            PolarisTextField(text: $northStar, prompt: Copy.step2Placeholder, font: PolarisTheme.Typography.northStar,
                             lineSpacing: PolarisTheme.Typography.northStarLineSpacing, axis: .vertical, lines: 1...3,
                             onSubmit: { finish() })
                .focused($focus, equals: .northStar)
                .fieldBox(focused: focus == .northStar || (theme.snapshot && northStar.isEmpty))
                .onAppear { if !theme.snapshot { focus = .northStar } }
            Spacer().frame(height: S.s)
            MetaText(text: Copy.step2Hint)
            if canCarryOver, let y = yesterday {
                Spacer().frame(height: S.s)
                Button { northStar = y.northStar } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.uturn.down")
                            .font(.system(size: 12, weight: .semibold))
                            .accessibilityHidden(true)
                        Text(Copy.carryOver + y.northStar)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .buttonStyle(QuietButtonStyle(height: 24))
                .padding(.leading, -8)
            }
            Spacer().frame(height: S.xxl)
            HStack(spacing: S.s) {
                Button(Copy.back) { go(to: 1) }
                    .buttonStyle(QuietButtonStyle())
                    .padding(.leading, -8)
                Spacer()
                // 空のとき、いちばん押しやすい見た目を「決めずに進む」に渡さない。⏎ は Quiet 側を押す。
                if northStarEmpty {
                    Button { finish() } label: { Text("\(Copy.skipNorthStar) ⏎") }
                        .buttonStyle(QuietButtonStyle())
                }
                Button { finish() } label: {
                    Text(northStarEmpty ? Copy.startWithStar : "\(Copy.startWithStar) ⏎")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(northStarEmpty)
            }
        }
    }

    private var northStarEmpty: Bool { northStar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // MARK: 進む・戻る・閉じる

    private func go(to next: Int) {
        if step == 2 { saveNorthStar() }
        forward = next > step
        withAnimation(PolarisTheme.Motion.sheetStep(theme.reduceMotion)) { step = next }
        onPrimary = false
        if next != 2 { rootFocused = true }
    }

    private func saveNorthStar() { model.setNorthStar(northStar) }

    private func finish() {
        saveNorthStar()
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
        if press.key == .tab && step != 2 && focus == nil {
            onPrimary.toggle(); return .handled
        }
        switch step {
        case 1:
            if let n = Int(press.characters), (1...model.modes.count).contains(n) {
                choose(model.modes[n - 1]); return .handled
            }
            if press.key == .downArrow || press.key == .upArrow {
                let modes = model.modes
                let current = modes.firstIndex { $0.id == modeID } ?? 0
                let next = min(max(current + (press.key == .downArrow ? 1 : -1), 0), modes.count - 1)
                onPrimary = false
                choose(modes[next]); return .handled
            }
            if press.key == .return || (press.key == .space && onPrimary) { go(to: 2); return .handled }
        default: break
        }
        return .ignored
    }
}

/// Step 1 の選択肢。h56 r10。選択中は ink の枠で示し、塗らない。
/// Increase Contrast では未選択の枠も border（35%）にし、選択中は 2pt にして差を保つ。
private struct ModeChoice: View {
    var mode: Mode
    var key: Int
    var selected: Bool
    var focused: Bool
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
                KeyCap(text: "\(key)")
            }
            .padding(.horizontal, 14)
            .frame(height: 56)
            .contentShape(shape)
            .overlay(shape.strokeBorder(border, lineWidth: borderWidth))
        }
        .buttonStyle(.plain)
        .focusRing(focused, radius: PolarisTheme.Radius.choice)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint("キー \(key)")
    }

    private var border: Color {
        if selected { return theme.ink }
        return theme.increaseContrast ? PolarisTheme.Palette.HighContrast.border : PolarisTheme.Palette.hairline
    }
    private var borderWidth: CGFloat {
        if selected { return theme.increaseContrast ? 2 : 1.5 }
        return 1
    }
}
