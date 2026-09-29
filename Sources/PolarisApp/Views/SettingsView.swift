import AppKit
import PolarisCore
import ServiceManagement
import SwiftUI

/// 設定。タブは作らず1画面。
struct SettingsView: View {
    var conflicts: Set<HotKeyCenter.Action>
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
            section("モード") {
                VStack(alignment: .leading, spacing: S.s) {
                    ForEach(Mode.defaults) { mode in
                        HStack(spacing: 12) {
                            Image(systemName: mode.symbol)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(PolarisTheme.Palette.Mode.tint(mode.tint))
                                .frame(width: 20)
                                .accessibilityHidden(true)
                            Text(mode.label).font(PolarisTheme.Typography.taskLead).foregroundStyle(theme.ink)
                            MetaText(text: AppNames.avoidSummary(mode.avoidApps))
                        }
                    }
                }
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
