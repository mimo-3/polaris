import SwiftUI

/// ⌃⌥H で隠しているときの寄り道表示。北極星と声の行だけ。ボタンなし・クリック透過。
struct MiniDetourView: View {
    @Environment(NoteModel.self) private var model
    @Environment(\.polaris) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let text = model.today.northStar
            Text(text.isEmpty ? Copy.northStarEmpty : WordWrap.japanese(text))
                .font(PolarisTheme.Typography.northStar)
                .lineSpacing(PolarisTheme.Typography.northStarLineSpacing)
                .foregroundStyle(theme.ink)
                .lineLimit(2)
                .padding(.vertical, PolarisTheme.Typography.northStarPadding)
                .fixedSize(horizontal: false, vertical: true)
            Spacer().frame(height: PolarisTheme.Space.l)
            VoiceLineView(compact: true)
        }
        .padding(.vertical, PolarisTheme.Space.l)
        .padding(.horizontal, PolarisTheme.Space.xl)
        .frame(width: PolarisTheme.Metrics.noteWidth, alignment: .leading)
        .background(PanelBackground(radius: PolarisTheme.Radius.note))
        .accessibilityElement(children: .combine)
    }
}
