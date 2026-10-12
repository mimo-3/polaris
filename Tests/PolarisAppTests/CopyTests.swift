import Testing
@testable import PolarisApp

struct CopyTests {
    @Test func testLegacyMCPSourceDisplaysKnownClientName() {
        let source = "mcp:codex"

        let name = Copy.clientName(source)

        #expect(name == "Codex")
    }

    @Test(arguments: [
        ("MCP: codex-mcp-client", "Codex"),
        ("MCP: claude-code", "Claude Code")
    ])
    func testNudgeSenderDisplaysKnownClientName(sender: String, expectedName: String) {
        let name = Copy.clientName(sender)

        #expect(name == expectedName)
    }

    @Test(arguments: ["Custom Client", "mcp:Custom Client", "MCP: Custom Client"])
    func testUnknownClientPreservesOriginalNameAfterRemovingPrefix(sender: String) {
        let name = Copy.clientName(sender)

        #expect(name == "Custom Client")
    }
}
