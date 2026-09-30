import AppKit
import PolarisCore
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// 設定。タブは作らず1画面。
struct SettingsView: View {
    var conflicts: Set<HotKeyCenter.Action>
    /// 最初に選んでおくモード。nil なら今日のモード。
    var initialModeID: String? = nil
    @Environment(\.polaris) private var theme
    @State var openAtLogin = SMAppService.mainApp.status == .enabled
    @State var copied = false

    private typealias S = PolarisTheme.Space

    private var mcpCommand: String {
        let bin = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/polaris-mcp").path
        return "claude mcp add polaris -- \(bin)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: S.xxl) {
            section(Copy.modesSection) {
                ModeSettings(selectedID: initialModeID)
            }
            section("ショートカット") {
                VStack(alignment: .leading, spacing: S.s) {
                    ForEach(HotKeyCenter.Action.allCases, id: \.rawValue) { action in
                        HStack {
                            Text(action.title).font(PolarisTheme.Typography.task).foregroundStyle(theme.ink)
                            Spacer()
                            MetaText(text: action.defaultBinding.label, color: theme.ink)
                        }
                        if conflicts.contains(action) {
                            Text("\(action.defaultBinding.label) はほかのアプリが使っている。別のキーを選んで。")
                                .font(PolarisTheme.Typography.voice)
                                .foregroundStyle(PolarisTheme.Palette.danger)
                        }
                    }
                }
            }
            section("ログイン時に開く") {
                Toggle("Mac にログインしたら Polaris を開く", isOn: $openAtLogin)
                    .toggleStyle(PolarisSwitchStyle())
                    .font(PolarisTheme.Typography.task)
                    .onChange(of: openAtLogin) { _, on in
                        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                        catch { openAtLogin = SMAppService.mainApp.status == .enabled }
                    }
            }
            section("MCP の登録") {
                VStack(alignment: .leading, spacing: S.s) {
                    Text(mcpCommand)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(theme.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(copied ? "コピーした" : "コマンドをコピー") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(mcpCommand, forType: .string)
                        copied = true
                    }
                    .buttonStyle(SmallButtonStyle(outlined: true))
                }
            }
        }
        .padding(S.xxl)
        .frame(width: 440, alignment: .leading)
        .background(PolarisTheme.Palette.surface)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: S.m) {
            Text(title).font(PolarisTheme.Typography.button).foregroundStyle(theme.ink)
            content()
        }
    }
}

/// モードの一覧と、選んだモードの名前・寄り道アプリの編集。
/// 一覧は選ぶためだけの行にし、編集欄は選んだ1件ぶんだけ下に出す（行ごとに入力欄を並べない）。
private struct ModeSettings: View {
    @Environment(NoteModel.self) private var model
    @Environment(\.polaris) private var theme
    @State private var selectedID: String?
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    private typealias S = PolarisTheme.Space

    init(selectedID: String?) { _selectedID = State(initialValue: selectedID) }

    private var selected: Mode? {
        model.modes.first { $0.id == (selectedID ?? model.mode.id) } ?? model.modes.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: S.m) {
            VStack(spacing: S.xs) {
                ForEach(model.modes) { mode in row(mode) }
            }
            Button(Copy.addMode) {
                commitName()
                selectedID = model.addMode(label: Copy.newModeLabel)
                name = Copy.newModeLabel
                nameFocused = true
            }
            .buttonStyle(SmallButtonStyle(outlined: true))
            if let mode = selected {
                Hairline()
                detail(mode)
            }
        }
        .onAppear { syncName() }
        .onChange(of: selected?.id) { _, _ in syncName() }
        .onChange(of: selected?.label) { _, _ in if !nameFocused { syncName() } }
        .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
    }

    // MARK: 一覧

    private func row(_ mode: Mode) -> some View {
        let isSelected = mode.id == selected?.id
        let shape = RoundedRectangle(cornerRadius: PolarisTheme.Radius.button, style: .continuous)
        return Button {
            commitName()
            selectedID = mode.id
        } label: {
            HStack(spacing: S.m) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(PolarisTheme.Palette.Mode.tint(mode.tint))
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(mode.label)
                    .font(isSelected ? PolarisTheme.Typography.taskLead : PolarisTheme.Typography.task)
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                Spacer(minLength: S.s)
                if !badges(mode).isEmpty { MetaText(text: badges(mode)) }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .contentShape(shape)
            .overlay(shape.strokeBorder(isSelected ? theme.ink : .clear, lineWidth: theme.increaseContrast ? 2 : 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel([mode.label, badges(mode)].filter { !$0.isEmpty }.joined(separator: "、"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func badges(_ mode: Mode) -> String {
        var parts: [String] = []
        if mode.id == PolarisCore.Mode.defaultMode.id { parts.append(Copy.defaultBadge) }
        if mode.id == model.mode.id { parts.append(Copy.todayBadge) }
        return parts.joined(separator: " · ")
    }

    // MARK: 選んだモード

    @ViewBuilder private func detail(_ mode: Mode) -> some View {
        VStack(alignment: .leading, spacing: S.l) {
            VStack(alignment: .leading, spacing: S.xs) {
                MetaText(text: Copy.modeName)
                PolarisTextField(text: $name, prompt: mode.label, font: PolarisTheme.Typography.task,
                                 onSubmit: { commitName() })
                    .focused($nameFocused)
                    .onChange(of: name) { _, text in
                        if text.count > TextRules.modeLabelMax { name = String(text.prefix(TextRules.modeLabelMax)) }
                    }
                    .fieldBox(focused: nameFocused)
                    .accessibilityLabel(Copy.modeName)
            }
            VStack(alignment: .leading, spacing: S.xs) {
                MetaText(text: Copy.avoidAppsTitle)
                if mode.avoidApps.isEmpty {
                    Text(Copy.noAvoid)
                        .font(PolarisTheme.Typography.task)
                        .foregroundStyle(theme.ink2)
                        .frame(height: 28, alignment: .leading)
                } else {
                    ForEach(mode.avoidApps, id: \.self) { bundleID in
                        let app = AppNames.name(for: bundleID)
                        HStack(spacing: S.s) {
                            Text(app)
                                .font(PolarisTheme.Typography.task)
                                .foregroundStyle(theme.ink)
                                .lineLimit(1)
                                .help(bundleID)
                            Spacer(minLength: S.s)
                            Button(Copy.removeApp) {
                                var next = mode
                                next.avoidApps.removeAll { $0 == bundleID }
                                model.saveMode(next)
                            }
                            .buttonStyle(SmallButtonStyle())
                            .accessibilityLabel(Copy.removeAppLabel(app))
                        }
                        .frame(height: 28)
                    }
                }
                Button(Copy.pickApps) { pickApps(for: mode) }
                    .buttonStyle(SmallButtonStyle(outlined: true))
                    .padding(.top, S.xs)
            }
            VStack(alignment: .leading, spacing: S.xs) {
                Button(Copy.deleteMode) {
                    let fallback = model.modes.first { $0.id != mode.id }?.id
                    model.removeMode(mode.id)
                    selectedID = fallback
                }
                .buttonStyle(SmallButtonStyle(outlined: true))
                .disabled(deleteBlocker(mode) != nil)
                if let reason = deleteBlocker(mode) {
                    Text(reason)
                        .font(PolarisTheme.Typography.voice)
                        .foregroundStyle(theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func deleteBlocker(_ mode: Mode) -> String? {
        if mode.id == PolarisCore.Mode.defaultMode.id { return Copy.cannotDeleteDefault }
        if mode.id == model.mode.id { return Copy.cannotDeleteCurrent }
        return nil
    }

    // MARK: 保存

    private func syncName() { name = selected?.label ?? "" }

    /// 空にしたら元の名前に戻す。変わっていなければ書かない。
    private func commitName() {
        guard var mode = selected else { return }
        let trimmed = TextRules.clean(name)
        guard !trimmed.isEmpty else { name = mode.label; return }
        guard trimmed != mode.label else { return }
        mode.label = trimmed
        model.saveMode(mode)
    }

    private func pickApps(for mode: Mode) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = Copy.pickAppsPrompt
        guard panel.runModal() == .OK else { return }
        let ids = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        var next = mode
        for id in ids where !next.avoidApps.contains(id) { next.avoidApps.append(id) }
        model.saveMode(next)
    }
}
