import AppKit
import PolarisCore
import SwiftUI

/// 付箋の最下段。優先順位の一番高いものを1件だけ出す。
/// 形は動かさない: 常駐中はどの中身も高さ16の1行に収め、小ボタン(24)は上下にはみ出させる。
/// banner の全文（2行＋出所）だけは、もともと高さが変わる展開中に出す。
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

    private var showsButtons: Bool { !compact && model.interactive }

    private func focused(_ index: Int) -> Bool { model.focusedTarget == .voiceAction(index) }

    @ViewBuilder private var content: some View {
        switch model.voice {
        case .mode: ModeLine(switchable: !compact)
        case .detour(let detour): detourLine(detour)
        case .transient(let t): transientLine(t)
        case .banner(let banner):
            if model.expanded && !compact { bannerFull(banner) } else { bannerLine(banner) }
        }
    }

    // MARK: 寄り道

    /// 「読書の日。戻る？ ［Slackを隠す］［5分だけ見る］」。収まらなければ「5分」に縮め、最後は文を省略する。
    @ViewBuilder private func detourLine(_ detour: Detour) -> some View {
        let message = Text(Copy.detour(detour.mode))
            .font(PolarisTheme.Typography.voiceEmphasis)
            .foregroundStyle(theme.ink)
        oneLine {
            if showsButtons {
                ViewThatFits(in: .horizontal) {
                    detourRow(message.fixedSize(), detour, snooze: Copy.fiveMinutes)
                    detourRow(message.fixedSize(), detour, snooze: Copy.fiveMinutesShort)
                    detourRow(message.lineLimit(1).truncationMode(.tail).layoutPriority(1), detour, snooze: Copy.fiveMinutesShort)
                }
            } else {
                message.lineLimit(1).truncationMode(.tail)
            }
        }
    }

    private func detourRow(_ message: some View, _ detour: Detour, snooze: String) -> some View {
        HStack(spacing: PolarisTheme.Space.s) {
            message
            Spacer(minLength: 0)
            Button(Copy.hideApp(detour.appName)) { DetourActions.hide(detour, model: model) }
                .buttonStyle(SmallButtonStyle(outlined: true, focused: focused(0)))
            Button(snooze) { DetourActions.snooze(detour, model: model) }
                .buttonStyle(SmallButtonStyle(focused: focused(1)))
                .accessibilityLabel(Copy.fiveMinutes)
        }
    }

    // MARK: 北極星の知らせ・エラー

    @ViewBuilder private func transientLine(_ t: Transient) -> some View {
        switch t {
        case .modeChanged(let mode):
            // モード表示と同じ glyph と位置にして、「この行はモード」という読み方を崩さない。
            HStack(spacing: 6) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(PolarisTheme.Palette.Mode.tint(mode.tint))
                    .frame(width: 16)
                    .accessibilityHidden(true)
                MetaText(text: Copy.modeChanged(mode.label), color: theme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .frame(height: 16)
        case .starEnded(_, let title, let next, let achieved):
            // 完了と同じ形にする。次の北極星は1段目に出ているので、ここでは繰り返さない。
            oneLine {
                HStack(spacing: PolarisTheme.Space.s) {
                    quoted(title, tail: achieved ? Copy.starAchievedTail : Copy.starDroppedTail,
                           font: PolarisTheme.Typography.voiceEmphasis)
                        .layoutPriority(1)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(Copy.starEndedSpoken(title, next: next, achieved: achieved))
                    Spacer(minLength: 0)
                    if showsButtons {
                        Button(Copy.undo) { model.undoStarEnded() }
                            .buttonStyle(SmallButtonStyle(outlined: true, focused: focused(0)))
                    }
                }
            }
        case .starSurfaced(let title):
            // 1段目はもう替わっているので、合図だけを光の色の記号で添える。
            oneLine {
                HStack(spacing: 6) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PolarisTheme.Palette.star)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    Text(Copy.starSurfaced(title))
                        .font(PolarisTheme.Typography.voiceEmphasis)
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
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

    /// 「{title}{tail}。title だけを末尾で省略し、」以降は必ず見せる。
    private func quoted(_ title: String, tail: String, font: Font, truncates: Bool = true) -> some View {
        HStack(spacing: 0) {
            Text(Copy.quoteOpen + title)
                .lineLimit(1)
                .truncationMode(.tail)
                .fixedSize(horizontal: !truncates, vertical: false)
            Text(tail)
                .lineLimit(1)
                .fixedSize()
        }
        .font(font)
        .foregroundStyle(theme.ink)
    }

    // MARK: banner

    /// 常駐中: 「PR終わったよ、北極星に戻ろう · Claude Code」を1行で、末尾を省略する。
    private func bannerLine(_ banner: Banner) -> some View {
        let client = Copy.clientName(banner.from)
        return oneLine {
            HStack(spacing: PolarisTheme.Space.s) {
                (Text(banner.text).foregroundStyle(theme.ink)
                 + Text(Copy.bannerFrom(client)).foregroundStyle(theme.ink2))
                    .font(PolarisTheme.Typography.voice)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                    .accessibilityLabel("\(banner.text)。\(Copy.from(client))")
                Spacer(minLength: 0)
                if showsButtons { dismissButton(client) }
            }
        }
    }

    /// 展開中: 全文（最大2行）＋出所。
    private func bannerFull(_ banner: Banner) -> some View {
        let client = Copy.clientName(banner.from)
        return HStack(alignment: .top, spacing: PolarisTheme.Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.text)
                    .font(PolarisTheme.Typography.voice)
                    .lineSpacing(PolarisTheme.Typography.voiceLineSpacing)
                    .foregroundStyle(theme.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                MetaText(text: Copy.from(client))
            }
            Spacer(minLength: 0)
            if showsButtons { dismissButton(client).frame(height: 16) }
        }
    }

    /// × は xmark 12pt を 20pt の枠に。当たり判定は 24。
    private func dismissButton(_ client: String) -> some View {
        Button { model.dismissBanner() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.ink2)
                .frame(width: 20, height: 20)
                .frame(width: PolarisTheme.Metrics.hitMin, height: PolarisTheme.Metrics.hitMin)
                .contentShape(Rectangle())
                .focusRing(focused(0), radius: PolarisTheme.Radius.small)
        }
        .buttonStyle(.plain)
        .padding(.trailing, -4)
        .accessibilityLabel(Copy.dismissBanner(client))
    }

    /// 声の行の器。高さは常に16。中のボタンは上下にはみ出す。
    private func oneLine(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 16)
    }
}

/// 付箋のクリック開閉は onTapGesture で、AX には出ない。モード表示の行の右側（モード名の切り替えメニューを除いた部分）を
/// 「ボタン」として出し、既定の操作（AXPress）と名前付きの操作で開閉できるようにする。
private struct ExpandAccessibility: ViewModifier {
    var enabled: Bool
    @Environment(NoteModel.self) private var model

    func body(content: Content) -> some View {
        if enabled {
            content
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Copy.panelToggle)
                .accessibilityAddTraits(.isButton)
                .accessibilityValue(model.expanded ? Copy.expandedValue : Copy.collapsedValue)
                .accessibilityHint(model.expanded ? Copy.collapseHint : Copy.expandHint)
                .accessibilityAction { model.setExpanded(!model.expanded) }
                .accessibilityAction(named: model.expanded ? Copy.collapseAction : Copy.expandAction) {
                    model.setExpanded(!model.expanded)
                }
        } else {
            content
        }
    }
}

/// 通常の声の行: モードの glyph ＋ 名前。展開中と全部完了の日は右に「済 n」。
/// モードの名前を押すと、その場でモードを切り替えられる。
struct ModeLine: View {
    var switchable = true
    @Environment(NoteModel.self) private var model
    @Environment(\.polaris) private var theme

    var body: some View {
        HStack(spacing: 6) {
            // ImageRenderer は Menu を描かないので、スナップショットでは見た目だけ出す。
            if switchable && !theme.snapshot {
                modeMenu
            } else {
                modeLabel(chevron: switchable)
            }
            HStack(spacing: 6) {
                Spacer(minLength: 0)
            }
            .modifier(ExpandAccessibility(enabled: model.interactive))
            if switchable && model.expanded { settingsButton }
        }
        .frame(height: 16)
    }

    /// 右下の歯車。小さく置き、当たり判定だけ 24 に広げる（行の高さ16からは上下にはみ出す）。
    private var settingsButton: some View {
        Button { (NSApp.delegate as? AppCoordinator)?.showSettings() } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.ink2)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: 24, height: 16)
        .padding(.trailing, -4)
        .noteHint(Hint.settings)
        .accessibilityLabel(Copy.settingsOpen)
    }

    private func modeLabel(chevron: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: model.mode.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(PolarisTheme.Palette.Mode.tint(model.mode.tint))
                .frame(width: 16)
                .accessibilityHidden(true)
            MetaText(text: model.mode.label)
            if chevron {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.ink2)
                    .accessibilityHidden(true)
            }
        }
    }

    private var modeMenu: some View {
        Menu {
            ForEach(model.modes) { mode in
                Button { model.setMode(mode.id) } label: {
                    if mode.id == model.mode.id {
                        Label(mode.label, systemImage: "checkmark")
                    } else {
                        Text(mode.label)
                    }
                }
            }
        } label: {
            modeLabel(chevron: true).contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!model.interactive)
        .noteHint(Hint.mode)
        .accessibilityLabel(Copy.modeMenu(model.mode.label))
    }
}
