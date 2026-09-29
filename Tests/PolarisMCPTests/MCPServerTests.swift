import Testing
import Foundation
import PolarisCore
import PolarisMCP

final class MCPServerTests {
    private var homes: [URL] = []
    deinit { for url in homes { try? FileManager.default.removeItem(at: url) } }
    private func server() throws -> MCPServer {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("polaris-backend-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        homes.append(directory)
        let date = Date(timeIntervalSince1970: 1_780_272_000)
        return MCPServer(store: PolarisStore(homeURL: directory, clock: { date }))
    }
    private func response(_ server: inout MCPServer, _ request: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: request)
        let line = server.handle(line: String(decoding: data, as: UTF8.self))
        return try decode(#require(line))
    }
    private func decode(_ line: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }
    private func call(_ server: inout MCPServer, _ name: String, arguments: [String: Any] = [:]) throws -> [String: Any] {
        let reply = try response(&server, ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": name, "arguments": arguments]])
        #expect(reply["error"] == nil)
        return try #require(reply["result"] as? [String: Any])
    }

    private func payload(_ result: [String: Any]) throws -> Any {
        let content = try #require(result["content"] as? [[String: Any]])
        let text = try #require(content.first?["text"] as? String)
        return try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }

    @Test func testInitializeListAndCallRoundTripPreservesIDAndDefaultsTaskToLater() throws {
        var subject = try server()
        let initialized = try response(&subject, ["jsonrpc": "2.0", "id": "client-1", "method": "initialize", "params": ["protocolVersion": "2024-11-05", "capabilities": [:], "clientInfo": ["name": "test", "version": "1"]]])
        #expect(initialized["id"] as? String == "client-1")
        let initialization = try #require(initialized["result"] as? [String: Any])
        #expect(initialization["capabilities"] != nil)
        #expect(initialization["protocolVersion"] != nil)
        #expect(subject.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)

        let listed = try response(&subject, ["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let list = try #require(listed["result"] as? [String: Any])
        let tools = try #require(list["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        #expect(names == Set(["polaris_get_today", "polaris_set_north_star", "polaris_set_mode", "polaris_list_modes", "polaris_add_task", "polaris_complete_task", "polaris_move_task", "polaris_remove_task", "polaris_list_later", "polaris_nudge", "polaris_get_history"]))
        for tool in tools {
            let schema = try #require(tool["inputSchema"] as? [String: Any])
            #expect(schema["type"] as? String == "object")
            #expect(!((tool["description"] as? String ?? "").isEmpty))
        }
        let added = try call(&subject, "polaris_add_task", arguments: ["title": "読書 📚"])
        #expect(added["isError"] as? Bool != true)
        let later = try call(&subject, "polaris_list_later")
        let tasks = try #require(payload(later) as? [[String: Any]])
        #expect(tasks.first?["title"] as? String == "読書 📚")
        #expect(tasks.first?["source"] as? String == "mcp:test")
        let today = try call(&subject, "polaris_get_today")
        #expect(today["isError"] as? Bool != true)
        let day = try #require(payload(today) as? [String: Any])
        #expect(day["laterCount"] as? Int == 1)
        #expect((day["now"] as? [Any])?.isEmpty == true)
    }

    @Test func testInvalidJSONAndUnknownMethodReturnProtocolErrors() throws {
        var subject = try server()
        let invalidLine = subject.handle(line: "{broken")
        let invalid = try decode(#require(invalidLine))
        #expect((invalid["error"] as? [String: Any])?["code"] as? Int == -32700)
        let unknown = try response(&subject, ["jsonrpc": "2.0", "id": 42, "method": "missing"])
        #expect(unknown["id"] as? Int == 42)
        #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32601)
        let malformed = try response(&subject, ["id": 1, "method": "ping"])
        #expect((malformed["error"] as? [String: Any])?["code"] as? Int == -32600)
    }

    @Test func testInvalidToolInputsReturnIsErrorInsteadOfProtocolError() throws {
        var subject = try server()
        let invalidCalls: [(String, [String: Any])] = [
            ("polaris_add_task", [:]),
            ("polaris_add_task", ["title": 12]),
            ("polaris_add_task", ["title": "task", "to": "done"]),
            ("polaris_add_task", ["title": "task", "position": -1]),
            ("polaris_add_task", ["title": "task", "position": 1.5]),
            ("polaris_complete_task", ["id": "not-a-uuid"]),
            ("polaris_set_mode", ["mode_id": "missing"]),
            ("polaris_nudge", ["text": "hello", "ttl_minutes": 0]),
            ("polaris_get_history", ["days": false]),
            ("missing_tool", [:])
        ]
        for (name, arguments) in invalidCalls {
            let result = try call(&subject, name, arguments: arguments)
            #expect(result["isError"] as? Bool == true)
        }
    }

    @Test func testPingRespondsAndNotificationsNeverRespond() throws {
        var subject = try server()
        let ping = try response(&subject, ["jsonrpc": "2.0", "id": 9, "method": "ping"])
        #expect(ping["id"] as? Int == 9)
        #expect(ping["result"] != nil)
        #expect(subject.handle(line: #"{"jsonrpc":"2.0","method":"ping"}"#) == nil)
        #expect(subject.handle(line: #"{"jsonrpc":"2.0","method":"unknown_notification"}"#) == nil)
    }
}
