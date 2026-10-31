import PolarisCore
import SwiftUI

/// 北極星のクイック編集。⏎ 保存、⌥⏎ 控えへ、⎋ 閉じる。
struct QuickEditView: View {
    enum Field: Hashable { case northStar }

    @Environment(NoteModel.self) private var model
    @Environment(\.polaris) private var theme
    var initialFocus: Field
    var close: () -> Void
    @State private var northStar: String
    @FocusState private var focus: Field?

    private typealias S = PolarisTheme.Space

    init(state: AppState, focus: Field, close: @escaping () -> Void) {
        initialFocus = focus
        self.close = close
        _northStar = .init(initialValue: state.today.northStar)
    }


    /// スナップショットでは実際のフォーカスが無いので、開いたときの位置を描く。
    private func isFocused(_ field: Field) -> Bool { theme.snapshot ? initialFocus == field : focus == field }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MetaText(text: Copy.northStarLabel)
            Spacer().frame(height: S.xs)
            PolarisTextField(text: $northStar, prompt: Copy.step2Placeholder, font: PolarisTheme.Typography.northStar,
                             lineSpacing: PolarisTheme.Typography.northStarLineSpacing, axis: .vertical, lines: 1...3,
                             onSubmit: { save(queueStar: NSEvent.modifierFlags.contains(.option)) })
                .focused($focus, equals: .northStar)
                .fieldBox(focused: isFocused(.northStar))
                .accessibilityLabel(Copy.northStarLabel)
            Spacer().frame(height: S.l)
            HStack(spacing: S.l) {
                ForEach(Copy.quickHintsStar, id: \.self) { MetaText(text: $0) }
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
    private func save(queueStar: Bool = false) {
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
        close()
    }
}
