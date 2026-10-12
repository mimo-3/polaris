import Testing
import Foundation
import PolarisCore
import PolarisMCP

final class MCPServerTests {
    private var homes: [URL] = []
    deinit { for url in homes { try? FileManager.default.removeItem(at: url) } }
    private func server() throws -> MCPServer {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/polaris-test-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        homes.append(directory)
        let date = Date(timeIntervalSince1970: 1_780_272_000)
        return MCPServer(store: PolarisStore(homeURL: directory, clock: { date }))
    }
    private func initializedServer(name: String = "test") throws -> MCPServer {
        var subject = try server()
        _ = try response(&subject, ["jsonrpc": "2.0", "id": 0, "method": "initialize", "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": name, "version": "1"]]])
        return subject
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
        #expect(names == Set(["polaris_get_today", "polaris_set_north_star", "polaris_list_north_stars", "polaris_add_north_star", "polaris_update_north_star", "polaris_complete_north_star", "polaris_switch_north_star", "polaris_remove_north_star", "polaris_get_north_star_log", "polaris_set_mode", "polaris_list_modes", "polaris_add_task", "polaris_update_task", "polaris_complete_task", "polaris_move_task", "polaris_remove_task", "polaris_rename_task", "polaris_list_later", "polaris_nudge", "polaris_get_history"]))
        #expect(tools.count == 20)
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
        var subject = try initializedServer()
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
        var subject = try initializedServer()
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
            ("polaris_add_task", ["title": String(repeating: "x", count: 201)]),
            ("polaris_rename_task", ["id": UUID().uuidString, "title": "x"])
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

    @Test func testUnknownToolIsProtocolErrorAndSessionRules() throws {
        var fresh = try server()
        let early = try response(&fresh, ["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        #expect((early["error"] as? [String: Any])?["code"] as? Int == -32600)
        #expect(fresh.handle(line: "   ") == nil)

        var subject = try initializedServer()
        let unknown = try response(&subject, ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "no_such_tool"]])
        #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32602)
        let again = try response(&subject, ["jsonrpc": "2.0", "id": 3, "method": "initialize", "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "other", "version": "1"]]])
        #expect((again["error"] as? [String: Any])?["code"] as? Int == -32600)
    }

    @Test func testRenameToolKeepsIDAndClientNameIsSanitized() throws {
        var subject = try initializedServer(name: "bad\u{202E}\nname")
        let added = try payload(call(&subject, "polaris_add_task", arguments: ["title": "元", "to": "now"])) as? [String: Any]
        let task = try #require(added?["task"] as? [String: Any])
        #expect(task["source"] as? String == "mcp:bad name")
        let id = try #require(task["id"] as? String)
        let renamed = try call(&subject, "polaris_rename_task", arguments: ["id": id, "title": "新"])
        #expect(renamed["isError"] as? Bool == false)
        let day = try #require(payload(renamed) as? [String: Any])
        let now = try #require(day["now"] as? [[String: Any]])
        #expect(now.first?["id"] as? String == id)
        #expect(now.first?["title"] as? String == "新")
    }

    @Test func testLineReaderDropsOversizedLines() throws {
        var chunks: [[UInt8]] = [Array("ab\n".utf8), Array(repeating: 0x78, count: 40), Array("\ncd\r\nef".utf8)]
        var reader = LineReader(maxBytes: 16) { buffer in
            guard !chunks.isEmpty else { return 0 }
            let next = chunks.removeFirst()
            buffer.replaceSubrange(0..<next.count, with: next)
            return next.count
        }
        var lines: [LineReader.Line] = []
        while let line = reader.next() { lines.append(line) }
        #expect(lines == [.text("ab"), .tooLong, .text("cd"), .text("ef")])
    }

    @Test func testListAndSetModeUseEditedModes() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/polaris-test-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        homes.append(directory)
        let date = Date(timeIntervalSince1970: 1_780_272_000)
        let store = PolarisStore(homeURL: directory, clock: { date })
        _ = try store.upsertMode(Mode(id: "deep", label: "集中の日", symbol: "circle", tint: "slate"))
        _ = try store.removeMode(id: "reading")
        var subject = MCPServer(store: store)
        _ = try response(&subject, ["jsonrpc": "2.0", "id": 0, "method": "initialize", "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "test", "version": "1"]]])

        let listed = try #require(try payload(call(&subject, "polaris_list_modes")) as? [[String: Any]])
        #expect(listed.compactMap { $0["id"] as? String } == ["work", "rest", "deep"])
        let set = try call(&subject, "polaris_set_mode", arguments: ["mode_id": "deep"])
        #expect(set["isError"] as? Bool == false)
        #expect(try store.read().today.mode.id == "deep")
        let removed = try call(&subject, "polaris_set_mode", arguments: ["mode_id": "reading"])
        #expect(removed["isError"] as? Bool == true)
    }

    @Test func testNorthStarToolsRoundTrip() throws {
        var subject = try initializedServer()
        _ = try call(&subject, "polaris_set_north_star", arguments: ["text": "今日の星"])
        let added = try #require(try payload(call(&subject, "polaris_add_north_star", arguments: ["text": "控えの星"])) as? [String: Any])
        let queuedID = try #require(added["id"] as? String)

        let listed = try #require(try payload(call(&subject, "polaris_list_north_stars")) as? [String: Any])
        #expect((listed["active"] as? [String: Any])?["text"] as? String == "今日の星")
        #expect((listed["queue"] as? [[String: Any]])?.count == 1)
        #expect(listed["pastCount"] as? Int == 0)

        let today = try #require(try payload(call(&subject, "polaris_get_today")) as? [String: Any])
        #expect(today["northStar"] as? String == "今日の星")
        #expect(today["northStarID"] is String)
        #expect((today["northStarQueue"] as? [[String: Any]])?.first?["id"] as? String == queuedID)

        let completed = try #require(try payload(call(&subject, "polaris_complete_north_star", arguments: ["outcome": "achieved"])) as? [String: Any])
        #expect((completed["completed"] as? [String: Any])?["text"] as? String == "今日の星")
        #expect((completed["next"] as? [String: Any])?["id"] as? String == queuedID)

        let log = try #require(try payload(call(&subject, "polaris_get_north_star_log")) as? [[String: Any]])
        #expect(log.first?["text"] as? String == "今日の星")

        let another = try #require(try payload(call(&subject, "polaris_add_north_star", arguments: ["text": "切り替え先"])) as? [String: Any])
        let switchID = try #require(another["id"] as? String)
        let switched = try call(&subject, "polaris_switch_north_star", arguments: ["id": switchID])
        #expect(switched["isError"] as? Bool == false)
        let after = try #require(try payload(call(&subject, "polaris_get_today")) as? [String: Any])
        #expect(after["northStarID"] as? String == switchID)

        let removed = try call(&subject, "polaris_remove_north_star", arguments: ["id": queuedID])
        #expect(removed["isError"] as? Bool == false)
    }

    @Test func testUpdateNorthStarAndTaskClearFieldsWithNull() throws {
        var subject = try initializedServer()
        let added = try #require(try payload(call(&subject, "polaris_add_north_star", arguments: [
            "text": "予約の星",
            "dueDate": "2026-06-15",
            "startsAt": "2026-06-01T12:00:00Z"
        ])) as? [String: Any])
        let starID = try #require(added["id"] as? String)
        #expect(added["dueDate"] as? String == "2026-06-15")
        #expect(added["startsAt"] as? String != nil)

        let updated = try #require(try payload(call(&subject, "polaris_update_north_star", arguments: [
            "id": starID,
            "text": "更新した星",
            "dueDate": NSNull(),
            "startsAt": NSNull()
        ])) as? [String: Any])
        #expect(updated["text"] as? String == "更新した星")
        #expect(updated["dueDate"] == nil)
        #expect(updated["startsAt"] == nil)

        let task = try #require(try payload(call(&subject, "polaris_add_task", arguments: [
            "title": "期限つき", "dueDate": "2026-06-20"
        ])) as? [String: Any])
        let taskObj = try #require(task["task"] as? [String: Any])
        let taskID = try #require(taskObj["id"] as? String)
        #expect(taskObj["dueDate"] as? String == "2026-06-20")

        let cleared = try #require(try payload(call(&subject, "polaris_update_task", arguments: [
            "id": taskID, "dueDate": NSNull()
        ])) as? [String: Any])
        #expect(cleared["dueDate"] == nil)
        #expect(cleared["title"] as? String == "期限つき")

        let renamed = try #require(try payload(call(&subject, "polaris_update_task", arguments: [
            "id": taskID, "title": "名前だけ"
        ])) as? [String: Any])
        #expect(renamed["title"] as? String == "名前だけ")
    }
}
