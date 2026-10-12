import Foundation

public enum PolarisVersion {
    public static let defaultVersion = "1.0.0"

    /// 同梱 MCP も署名済みアプリのバージョンを使う。単体バイナリは既定値。
    public static var current: String {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        guard executable.deletingLastPathComponent().lastPathComponent == "MacOS" else { return defaultVersion }
        let plist = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
        return version(infoPlistURL: plist)
    }

    public static func version(infoPlistURL: URL) -> String {
        guard let data = try? Data(contentsOf: infoPlistURL),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = info["CFBundleShortVersionString"] as? String, !version.isEmpty else { return defaultVersion }
        return version
    }
}
