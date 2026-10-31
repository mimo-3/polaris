import Testing
import Foundation
import PolarisCore
import PolarisMCP

final class OSSHardeningMCPTests {
    private var homes: [URL] = []
    deinit { for home in homes { try? FileManager.default.removeItem(at: home) } }
    private func session(name: String = "test", version: String = "2025-06-18") throws -> (MCPServer, PolarisStore, [String: Any]) {
        let home = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("goalonly-mcp-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        homes.append(home)
        let date = Date(timeIntervalSince1970: 1_780_272_000)
        let store = PolarisStore(homeURL: home, clock: { date })
        var server = MCPServer(store: store)
        let initialized = try response(&server, ["jsonrpc": "2.0", "id": 0, "method": "initialize", "params": ["protocolVersion": version, "capabilities": [:], "clientInfo": ["name": name, "version": "1"]]])
        let notified = server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        #expect(notified == nil)
        return (server, store, initialized)
    }
    private func response(_ server: inout MCPServer, _ request: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: request)
        let raw = server.handle(line: String(decoding: data, as: UTF8.self))
        let line = try #require(raw)
        return try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }
    private func call(_ server: inout MCPServer, name: String, arguments: [String: Any]) throws -> [String: Any] {
        let reply = try response(&server, ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": arguments]])
        #expect(reply["error"] == nil)
        return try #require(reply["result"] as? [String: Any])
    }

    @Test func testNorthStarWritePreservesLegacyItemsWithoutExposingThem() throws {
        var (server, store, _) = try session()
        _ = try store.addTask(title: "旧いま", to: .now)
        let finished = try store.addTask(title: "旧完了", to: .now).task
        _ = try store.completeTask(id: finished.id)
        _ = try store.addTask(title: "旧あとで", to: .later)
        let before = try store.read()
        let result = try call(&server, name: "polaris_set_north_star", arguments: ["text": "今日の目標"])
        #expect(result["isError"] as? Bool == false)
        let after = try store.read()
        #expect(after.today.now == before.today.now)
        #expect(after.today.done == before.today.done)
        #expect(after.later == before.later)
        #expect(after.schemaVersion == before.schemaVersion)
        let content = try #require(result["content"] as? [[String: Any]])
        let text = try #require(content.first?["text"] as? String)
        let day = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(day["northStar"] as? String == "今日の目標")
        for key in ["now", "done", "later"] { #expect(day[key] == nil) }
    }

    @Test func testFailedNorthStarUpdateKeepsTextScheduleAndRevision() throws {
        var (server, store, _) = try session()
        let star = try store.addNorthStar(text: "元の星", dueDate: "2026-06-20", startsAt: Date(timeIntervalSince1970: 1_780_280_000))
        let before = try store.read()

        let result = try call(&server, name: "polaris_update_north_star", arguments: ["id": star.id.uuidString, "text": "変えてはいけない", "dueDate": "invalid", "startsAt": NSNull()])

        #expect(result["isError"] as? Bool == true)
        #expect(try store.read() == before)
    }

    @Test func testSuccessfulMultiFieldUpdatesUseOneRevisionEach() throws {
        var (server, store, _) = try session()
        let star = try store.addNorthStar(text: "元の星")
        let before = try store.read().revision
        let starResult = try call(&server, name: "polaris_update_north_star", arguments: ["id": star.id.uuidString, "text": "新しい星", "dueDate": "2026-06-20", "startsAt": "2026-06-15T12:00:00Z"])
        #expect(starResult["isError"] as? Bool == false)
        #expect(try store.read().revision == before + 1)
    }

    @Test func testMarchProtocolFallsBackToSupportedNonBatchVersion() throws {
        var (server, _, initialized) = try session(version: "2025-03-26")
        let result = try #require(initialized["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        let raw = server.handle(line: #"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#)
        let batch = try #require(raw)
        let rejected = try #require(JSONSerialization.jsonObject(with: Data(batch.utf8)) as? [String: Any])
        #expect((rejected["error"] as? [String: Any])?["code"] as? Int == -32600)
    }

    @Test func testRequestIDsRejectNullFractionAndBooleanButKeepIntegerAndString() throws {
        var (server, _, _) = try session()
        for id: Any in [NSNull(), 1.5, true, false] {
            let reply = try response(&server, ["jsonrpc": "2.0", "id": id, "method": "ping"])
            #expect((reply["error"] as? [String: Any])?["code"] as? Int == -32600)
            #expect(reply["id"] is NSNull)
        }
        for id in [-42, 0, 42] {
            let reply = try response(&server, ["jsonrpc": "2.0", "id": id, "method": "ping"])
            #expect(reply["id"] as? Int == id)
            #expect(reply["error"] == nil)
        }
        let stringReply = try response(&server, ["jsonrpc": "2.0", "id": "client-42", "method": "ping"])
        #expect(stringReply["id"] as? String == "client-42")
    }

    @Test func testNudgeAlwaysIdentifiesMCPOrigin() throws {
        var (server, store, _) = try session(name: "Polaris\u{202e}\n通知")
        let result = try call(&server, name: "polaris_nudge", arguments: ["text": "戻ろう"])
        #expect(result["isError"] as? Bool == false)
        #expect(try store.read().banner?.from == "MCP: Polaris 通知")
    }

    @Test(arguments: [String(repeating: "a", count: 100), String(repeating: "星", count: 100)])
    func testNudgeTruncatesSenderAfterAddingMCPPrefix(name: String) throws {
        var (server, store, _) = try session(name: name)

        let result = try call(&server, name: "polaris_nudge", arguments: ["text": "戻ろう"])

        #expect(result["isError"] as? Bool == false)
        let sender = try #require(store.read().banner?.from)
        #expect(sender == "MCP: " + String(name.prefix(TextRules.clientMax - 5)))
        #expect(sender.unicodeScalars.count == TextRules.clientMax)
    }

    @Test func testCombiningScalarBombReturnsToolError() throws {
        var (server, store, _) = try session()
        let before = try store.read()
        let result = try call(&server, name: "polaris_add_north_star", arguments: ["text": "x" + String(repeating: "\u{301}", count: 10000)])
        #expect(result["isError"] as? Bool == true)
        #expect(try store.read() == before)
    }

    @Test func testInvalidUTF8LineIsReportedAndNextLineRemainsReadable() throws {
        var chunks: [[UInt8]] = [[0x22, 0xC3], [0x28, 0x22, 0x0A], Array("正常\n".utf8), [0xFF]]
        var reader = LineReader(maxBytes: 100) { buffer in
            guard !chunks.isEmpty else { return 0 }
            let chunk = chunks.removeFirst()
            buffer.replaceSubrange(0..<chunk.count, with: chunk)
            return chunk.count
        }
        var lines: [LineReader.Line] = []
        while let line = reader.next() { lines.append(line) }
        #expect(lines == [.invalidUTF8, .text("正常"), .invalidUTF8])
        let error = try #require(JSONSerialization.jsonObject(with: Data(MCPServer.parseErrorResponse().utf8)) as? [String: Any])
        #expect((error["error"] as? [String: Any])?["code"] as? Int == -32700)
    }

    @Test func testUTF8ScalarSplitAcrossChunksIsAccepted() {
        let text = "星🙂"
        var chunks = Array(text.utf8).map { [$0] } + [[UInt8(0x0A)]]
        var reader = LineReader(maxBytes: 100) { buffer in
            guard !chunks.isEmpty else { return 0 }
            let chunk = chunks.removeFirst()
            buffer.replaceSubrange(0..<chunk.count, with: chunk)
            return chunk.count
        }
        let line = reader.next()
        #expect(line == .text(text))
    }


    @Test func testRelativePolarisHomeIsRejectedByMCPProcess() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("goalonly-relative-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        homes.append(directory)
        let process = Process()
        process.executableURL = root.appendingPathComponent(".build/debug/polaris-mcp")
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging(["POLARIS_HOME": "goalonly-not-absolute"]) { _, new in new }
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"polaris_list_north_stars","arguments":{}}}"#
        ].joined(separator: "\n") + "\n"
        input.fileHandleForWriting.write(Data(requests.utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        #expect(process.terminationStatus == 0)
        #expect(lines.count == 2)
        let last = try #require(lines.last)
        let reply = try #require(JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any])
        #expect((reply["result"] as? [String: Any])?["isError"] as? Bool == true)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("goalonly-not-absolute").path))
    }

}
