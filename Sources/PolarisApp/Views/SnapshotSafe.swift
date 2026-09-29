import SwiftUI

/// ImageRenderer は AppKit 由来のビュー（入力欄・スクロール・メニュー）を描けない。
/// スナップショットのときだけ同じ見た目の Text などに差し替える。

struct PolarisTextField: View {
    @Binding var text: String
    var prompt: String
    var font: Font
    var lineSpacing: CGFloat = 0
    var axis: Axis = .horizontal
    var lines: ClosedRange<Int> = 1...1
    var onSubmit: () -> Void = {}
    @Environment(\.polaris) private var theme

    var body: some View {
        if theme.snapshot {
            Text(text.isEmpty ? prompt : text)
                .font(font)
                .lineSpacing(lineSpacing)
                .foregroundStyle(text.isEmpty ? theme.ink2 : theme.ink)
                .lineLimit(lines.upperBound)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(theme.ink2), axis: axis)
                .textFieldStyle(.plain)
                .font(font)
                .lineSpacing(lineSpacing)
                .foregroundStyle(theme.ink)
                .lineLimit(lines)
                .onSubmit(onSubmit)
        }
    }
}

struct PolarisScroll<Content: View>: View {
    var height: CGFloat
    var showsIndicators: Bool
    @ViewBuilder var content: Content
    @Environment(\.polaris) private var theme

    var body: some View {
        if theme.snapshot {
            content.frame(height: height, alignment: .top).clipped()
        } else {
            ScrollView(.vertical) { content }
                .scrollIndicators(showsIndicators ? .automatic : .never)
                .frame(height: height)
        }
    }
}
