import Foundation

/// 状態ファイルに入る文字列の上限と正規化。アプリと MCP の両方がストア経由でこれを通る。
public enum TextRules {
    public static let titleMax = 200
    public static let northStarMax = 200
    public static let starQueueMax = 20
    public static let noteMax = 500
    public static let bannerMax = 280
    public static let clientMax = 64
    public static let modeLabelMax = 20
    public static let bundleIDMax = 255

    /// 改行・タブは空白に、それ以外の制御文字と双方向制御文字は取り除き、前後の空白を落とす。
    public static func clean(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "\n" || scalar == "\r" || scalar == "\t" || scalar == "\u{2028}" || scalar == "\u{2029}" {
                scalars.append(" ")
            } else if !isDropped(scalar) {
                scalars.append(scalar)
            }
        }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 正規化してから上限を確かめる。超えたら invalidInput。
    public static func checked(_ text: String, max: Int, label: String) throws -> String {
        let cleaned = clean(text)
        guard cleaned.count <= max else { throw PolarisError.invalidInput("\(label)は\(max)文字以内にしてください") }
        return cleaned
    }

    /// MCP のクライアント名。拒否はせず、正規化して上限で切る。空なら unknown。
    public static func clientName(_ raw: String) -> String {
        let cleaned = String(clean(raw).prefix(clientMax))
        return cleaned.isEmpty ? "unknown" : cleaned
    }

    private static func isDropped(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.generalCategory == .control { return true }
        switch scalar.value {
        case 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: return true
        default: return false
        }
    }
}
