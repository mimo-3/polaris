import Foundation
import PolarisMCP

var server = MCPServer()
var reader = LineReader.standardInput(maxBytes: MCPServer.maxLineBytes)
while let line = reader.next() {
    let response: String?
    switch line {
    case .text(let text): response = server.handle(line: text)
    case .tooLong: response = MCPServer.tooLongResponse()
    }
    if let response {
        FileHandle.standardOutput.write(Data((response + "\n").utf8))
    }
}
