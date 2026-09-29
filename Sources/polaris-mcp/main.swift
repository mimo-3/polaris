import Foundation
import PolarisMCP

var server = MCPServer()
while let line = readLine() {
    if let response = server.handle(line: line) {
        FileHandle.standardOutput.write(Data((response + "\n").utf8))
    }
}
