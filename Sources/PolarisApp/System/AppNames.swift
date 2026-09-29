import AppKit

/// bundle ID から人が読むアプリ名を引く。
enum AppNames {
    private static let known: [String: String] = [
        "com.tinyspeck.slackmacgap": "Slack",
        "com.anthropic.claudefordesktop": "Claude",
        "com.apple.Terminal": "ターミナル",
        "com.googlecode.iterm2": "iTerm",
        "com.mitchellh.ghostty": "Ghostty",
        "com.todesktop.230313mzl4w4u92": "Cursor",
    ]

    static func name(for bundleID: String) -> String {
        if let known = known[bundleID] { return known }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }

    /// 支度シートの補足。長くなるので2つまで出して「など」で畳む。
    static func avoidSummary(_ bundleIDs: [String]) -> String {
        guard !bundleIDs.isEmpty else { return Copy.noAvoid }
        let names = bundleIDs.prefix(2).map(name(for:))
        let more = bundleIDs.count > 2 ? "など" : ""
        return "\(names.joined(separator: "・"))\(more)を寄り道として知らせる"
    }
}
