import PolarisCore
import SwiftUI

/// 付箋の最下段。優先順位の一番高いものを1件だけ出す。形は変えず、中身だけ入れ替える。
struct VoiceLineView: View {
    /// 寄り道の簡易パネルではボタンを出さない。
    var compact = false
    @Environment(NoteModel.self) private var model
    @Environment(\.polaris) private var theme

    var body: some View {
        ZStack(alignment: .topLeading) {
            content
                .id(model.voice.id)
                .transition(transition)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var transition: AnyTransition {
        theme.reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: 4)),
                                                    removal: .opacity)
    }

    private var showsButtons: Bool { !compact && (!model.clickThrough || model.optionPeek) }

    @ViewBuilder private var content: some View {
        switch model.voice {
        case .mode: ModeLine(showCounts: model.expanded)
        case .detour(let detour): detourLine(detour)
        case .transient(let t): transientLine(t)
        case .banner(let banner): bannerLine(banner)
        }
    }

    private func detourLine(_ detour: Detour) -> some View {
        VStack(alignment: .leading, spacing: PolarisTheme.Space.s) {
            Text(Copy.detour(detour.mode))
                .font(PolarisTheme.Typography.voiceEmphasis)
                .foregroundStyle(theme.ink)
            if showsButtons {
                HStack(spacing: PolarisTheme.Space.s) {
                    Button(Copy.hideApp(detour.appName)) { DetourActions.hide(detour, model: model) }
                        .buttonStyle(SmallButtonStyle(outlined: true))
                    Button(Copy.fiveMinutes) { DetourActions.snooze(detour, model: model) }
                        .buttonStyle(SmallButtonStyle())
                }
            }
        }
    }

    @ViewBuilder private func transientLine(_ t: Transient) -> some View {
        switch t {
        case .undo:
            HStack(spacing: PolarisTheme.Space.s) {
                Text(Copy.completed)
                    .font(PolarisTheme.Typography.voiceEmphasis)
                    .foregroundStyle(theme.ink)
                if showsButtons {
                    Button(Copy.undo) { model.undo() }
                        .buttonStyle(SmallButtonStyle(outlined: true))
                        .keyboardShortcut("z", modifiers: .command)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 16)
        case .overflow(_, let title, let client):
            VStack(alignment: .leading, spacing: PolarisTheme.Space.xs) {
                Text(client.map { Copy.overflowMCP(title, $0) } ?? Copy.overflow(title))
                    .font(PolarisTheme.Typography.voice)
                    .foregroundStyle(theme.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: PolarisTheme.Space.s) {
                    MetaText(text: Copy.nowFull)
                    if showsButtons && model.swapping == nil {
                        Button(Copy.swap) { model.beginSwap() }
                            .buttonStyle(SmallButtonStyle(outlined: true))
                    }
                }
            }
        case .error(let message):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PolarisTheme.Palette.danger)
                    .accessibilityHidden(true)
                Text(message)
                    .font(PolarisTheme.Typography.voice)
                    .foregroundStyle(theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func bannerLine(_ banner: Banner) -> some View {
        HStack(alignment: .top, spacing: PolarisTheme.Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.text)
                    .font(PolarisTheme.Typography.voice)
                    .foregroundStyle(theme.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                MetaText(text: Copy.from(Copy.clientName(banner.from)))
            }
            Spacer(minLength: 0)
            if showsButtons {
                Button { model.dismissBanner() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.ink2)
                        .frame(width: PolarisTheme.Metrics.hitMin, height: PolarisTheme.Metrics.hitMin)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, -4).padding(.trailing, -6)
                .accessibilityLabel("閉じる")
            }
        }
    }
}

/// 通常の声の行: モードの glyph ＋ 名前。展開中は右に「済 n」、透過中は ⊘。
struct ModeLine: View {
    var showCounts: Bool
    var closed = false
    @Environment(NoteModel.self) private var model
    @Environment(\.polaris) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: model.mode.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(PolarisTheme.Palette.Mode.tint(model.mode.tint))
                .frame(width: 16)
                .accessibilityHidden(true)
            MetaText(text: closed ? Copy.dayClosed(model.mode.label) : model.mode.label)
            Spacer(minLength: 0)
            if showCounts && !model.today.done.isEmpty && !closed {
                MetaText(text: Copy.done(model.today.done.count))
                    .contentTransition(.numericText())
            }
            if model.clickThrough {
                Image(systemName: "cursorarrow.slash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(model.optionPeek ? theme.ink : theme.ink2)
                    .accessibilityLabel(Copy.clickThroughIcon)
            }
        }
        .frame(height: 16)
    }
}
