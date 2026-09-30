import PolarisCore
import SwiftUI

/// ⌃⌥P / ⌃⌥N のクイック編集。⏎ 保存、⌥⏎ あとでに入れる、⎋ 閉じる。
struct QuickEditView: View {
    enum Field: Hashable { case northStar, add }

    @Environment(NoteModel.self) private var model
    @Environment(\.polaris) private var theme
    var initialFocus: Field
    var close: () -> Void
    @State private var northStar: String
    @State private var addText = ""
    @FocusState private var focus: Field?

    private typealias S = PolarisTheme.Space

    init(state: AppState, focus: Field, addText: String = "", close: @escaping () -> Void) {
        initialFocus = focus
        self.close = close
        _northStar = .init(initialValue: state.today.northStar)
        _addText = .init(initialValue: addText)
    }

    private var remaining: Int { max(0, 3 - model.today.now.count) }

    /// スナップショットでは実際のフォーカスが無いので、開いたときの位置を描く。
    private func isFocused(_ field: Field) -> Bool { theme.snapshot ? initialFocus == field : focus == field }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MetaText(text: Copy.northStarLabel)
            Spacer().frame(height: S.xs)
            PolarisTextField(text: $northStar, prompt: Copy.step2Placeholder, font: PolarisTheme.Typography.northStar,
                             lineSpacing: PolarisTheme.Typography.northStarLineSpacing, axis: .vertical, lines: 1...3,
                             onSubmit: { save(toLater: false, queueStar: NSEvent.modifierFlags.contains(.option)) })
                .focused($focus, equals: .northStar)
                .fieldBox(focused: isFocused(.northStar))
                .accessibilityLabel(Copy.northStarLabel)
            Spacer().frame(height: S.m)
            MetaText(text: Copy.addLabel)
            Spacer().frame(height: S.xs)
            PolarisTextField(text: $addText, prompt: Copy.addPlaceholder, font: PolarisTheme.Typography.task,
                             onSubmit: { save(toLater: NSEvent.modifierFlags.contains(.option)) })
                .frame(height: 20)
                .focused($focus, equals: .add)
                .fieldBox(focused: isFocused(.add))
                .accessibilityLabel(Copy.addLabel)
            Spacer().frame(height: S.xs)
            MetaText(text: remaining > 0 ? Copy.toNow(remaining) : Copy.toLaterFull)
            Spacer().frame(height: S.l)
            HStack(spacing: S.l) {
                ForEach(isFocused(.northStar) ? Copy.quickHintsStar : Copy.quickHints, id: \.self) { MetaText(text: $0) }
            }
        }
        .padding(S.xl)
        .frame(width: PolarisTheme.Metrics.quickEditWidth, alignment: .leading)
        .background(PanelBackground(radius: PolarisTheme.Radius.quickEdit))
        .onAppear { if !theme.snapshot { focus = initialFocus } }
        .onExitCommand { close() }
        .onKeyPress(.escape) { close(); return .handled }
    }

    /// `queueStar` は北極星の欄での ⌥⏎。今日の北極星は変えず、書いた文を控えの末尾に足す。
    private func save(toLater: Bool, queueStar: Bool = false) {
        if queueStar {
            // 控えが満杯なら閉じない。書いた文を失わないようにする。
            guard model.state.queuedStars.count < TextRules.starQueueMax else {
                model.show(.error(Copy.starsQueueFull))
                return
            }
            model.queueNorthStar(northStar)
        } else {
            model.setNorthStar(northStar)
        }
        let title = addText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { model.addTask(title, to: toLater ? .later : .now) }
        close()
    }
}
