import Foundation

/// 改行区切りで読む。上限を超えた行は中身を溜めずに読み捨て、`.tooLong` として返す。
public struct LineReader {
    public enum Line: Equatable { case text(String), tooLong, invalidUTF8 }

    private let maxBytes: Int
    private let readChunk: (inout [UInt8]) -> Int
    private var buffer: [UInt8] = []
    private var pending: [UInt8] = []
    private var cursor = 0
    private var overflowing = false
    private var finished = false

    /// `readChunk` は配列を埋めて読んだバイト数を返す。0 以下で終わり。
    public init(maxBytes: Int, readChunk: @escaping (inout [UInt8]) -> Int) {
        self.maxBytes = maxBytes; self.readChunk = readChunk
    }

    public static func standardInput(maxBytes: Int) -> LineReader {
        LineReader(maxBytes: maxBytes) { chunk in
            chunk.withUnsafeMutableBytes { raw in
                while true {
                    let n = Darwin.read(STDIN_FILENO, raw.baseAddress, raw.count)
                    if n < 0 && errno == EINTR { continue }
                    return n
                }
            }
        }
    }

    public mutating func next() -> Line? {
        while true {
            while cursor < pending.count {
                let byte = pending[cursor]; cursor += 1
                if byte == 0x0A { return takeLine() }
                if overflowing { continue }
                buffer.append(byte)
                if buffer.count > maxBytes { overflowing = true; buffer.removeAll(keepingCapacity: false) }
            }
            if finished {
                if overflowing || !buffer.isEmpty { return takeLine() }
                return nil
            }
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let n = readChunk(&chunk)
            if n <= 0 { finished = true; pending = []; cursor = 0; continue }
            pending = Array(chunk.prefix(n)); cursor = 0
        }
    }

    private mutating func takeLine() -> Line {
        defer { buffer.removeAll(keepingCapacity: true); overflowing = false }
        if overflowing { return .tooLong }
        if buffer.last == 0x0D { buffer.removeLast() }
        guard let text = String(bytes: buffer, encoding: .utf8) else { return .invalidUTF8 }
        return .text(text)
    }
}
