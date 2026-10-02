import SwiftUI

extension View {
    /// ホバーで、押すと何が起きるかを小さな吹き出しで出す。`id` は同じ文言の場所が並ぶとき（行ごとの ✓ など）に分ける。
    func noteHint(_ text: String, id: String? = nil) -> some View {
        modifier(NoteHintTarget(text: text, id: id ?? text))
    }
}

/// 案内を出す場所の枠を付箋の座標で覚えておく。当たり判定は NoteModel が pointer で行う。
private struct NoteHintTarget: ViewModifier {
    let text: String
    let id: String
    @Environment(NoteModel.self) private var model

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(NoteCard.space)) }) { frame in
                model.hintTargets[id] = (text, frame)
            }
            .onDisappear { model.hintTargets[id] = nil }
    }
}

/// 付箋の上に重ねる案内の吹き出し。対象の下に出し、下に余白がなければ上に出す。左右は付箋の内側に収める。
struct NoteHintOverlay: View {
    @Environment(NoteModel.self) private var model
    @Environment(\.polaris) private var theme
    @State private var size: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            if let hint = model.hint, model.expanded, model.editing == nil {
                HintBubble(text: hint.text)
                    .onGeometryChange(for: CGSize.self, of: { $0.size }) { size = $0 }
                    .offset(offset(for: hint.frame, in: proxy.size))
                    .opacity(size == .zero ? 0 : 1)
                    .transition(.opacity)
                    .id(hint.text)
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: theme.reduceMotion ? 0 : 0.12), value: model.hint)
    }

    private func offset(for frame: CGRect, in bounds: CGSize) -> CGSize {
        let gap: CGFloat = 6
        let inset: CGFloat = 8
        let below = frame.maxY + gap
        let y = below + size.height <= bounds.height - inset ? below : max(inset, frame.minY - gap - size.height)
        let x = min(max(inset, frame.midX - size.width / 2), bounds.width - inset - size.width)
        return CGSize(width: x, height: y)
    }
}

/// 案内の吹き出し。付箋とつまみの両方で使う。
struct HintBubble: View {
    var text: String
    @Environment(\.polaris) private var theme

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(PolarisTheme.Palette.surface)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.ink.opacity(0.88)))
    }
}
