import AppKit
import NaturalLanguage

/// 和文を語の境界で折り返すための下ごしらえ。表示用の Text にだけ使い、入力欄には使わない。
/// 語の内側の文字間に U+2060 WORD JOINER を挟むと、CoreText はそこで改行しなくなる。
@MainActor
enum WordWrap {
    private static let joiner: Character = "\u{2060}"
    private static var cache: [String: String] = [:]

    /// `width` を超える1語だけは WJ を入れず、ふつうに折り返させる。
    static func japanese(_ text: String, font: NSFont = PolarisTheme.Typography.northStarNSFont(),
                         width: CGFloat = PolarisTheme.Metrics.noteWidth - PolarisTheme.Space.xl * 2) -> String {
        guard !text.isEmpty else { return text }
        let key = "\(width)|\(text)"
        if let hit = cache[key] { return hit }

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(.japanese)
        tokenizer.string = text
        var result = ""
        var cursor = text.startIndex
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            result += text[cursor..<range.lowerBound]
            let word = String(text[range])
            result += fits(word, font: font, width: width) ? join(word) : word
            cursor = range.upperBound
            return true
        }
        result += text[cursor...]
        if cache.count > 64 { cache.removeAll() }
        cache[key] = result
        return result
    }

    private static func join(_ word: String) -> String {
        guard word.count > 1 else { return word }
        return word.map(String.init).joined(separator: String(joiner))
    }

    private static func fits(_ word: String, font: NSFont, width: CGFloat) -> Bool {
        (word as NSString).size(withAttributes: [.font: font]).width <= width
    }
}
