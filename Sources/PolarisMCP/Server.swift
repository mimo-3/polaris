import Foundation
import CoreFoundation
import PolarisCore

/// One instance per stdio session. Requests are handled sequentially.
public struct MCPServer: Sendable {
    private let store: PolarisStore
    private var clientName = "unknown"
    private var initialized = false
    public init(store: PolarisStore = PolarisStore()) { self.store = store }

    /// 1行の上限。超えた行は読み捨てて Invalid Request を返す。
    public static let maxLineBytes = 1 << 20
    public static func tooLongResponse() -> String {
        #"{"error":{"code":-32600,"message":"Request too large"},"id":null,"jsonrpc":"2.0"}"#
    }

    public mutating func handle(line: String) -> String? {
        // 行区切りのトランスポートで空行には応答しない。
        if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        let parsed: Any
        do { parsed = try JSONSerialization.jsonObject(with: Data(line.utf8), options: [.fragmentsAllowed]) }
        catch { return encode(self.error(id: NSNull(), code: -32700, message: "Parse error")) }
        guard let request = parsed as? [String: Any], request["jsonrpc"] as? String == "2.0",
              let method = request["method"] as? String,
              request["id"] == nil || validID(request["id"]!),
              request["params"] == nil || request["params"] is [String: Any] || request["params"] is [Any] else {
            return encode(self.error(id: NSNull(), code: -32600, message: "Invalid Request"))
        }
        // JSON-RPC notifications never receive a response, including unknown notifications.
        guard let id = request["id"] else { return nil }
        if let params = request["params"], !(params is [String: Any]) {
            return encode(self.error(id: id, code: -32602, message: "Expected named parameters"))
        }
        let params = request["params"] as? [String: Any] ?? [:]
        if method == "initialize" && initialized {
            return encode(self.error(id: id, code: -32600, message: "Already initialized"))
        }
        if method != "initialize" && method != "ping" && !initialized {
            return encode(self.error(id: id, code: -32600, message: "Not initialized"))
        }
        let result: [String: Any]
        switch method {
        case "initialize":
            guard let version = params["protocolVersion"] as? String,
                  let client = params["clientInfo"] as? [String: Any], let name = client["name"] as? String,
                  client["version"] is String, params["capabilities"] is [String: Any] else {
                return encode(self.error(id: id, code: -32602, message: "protocolVersion, capabilities and clientInfo are required"))
            }
            clientName = TextRules.clientName(name)
            initialized = true
            let supported = ["2024-11-05", "2025-03-26", "2025-06-18"]
            result = ["protocolVersion": supported.contains(version) ? version : "2025-06-18",
                      "capabilities": ["tools": ["listChanged": false]],
                      "serverInfo": ["name": "polaris", "version": "1.0.0"]]
        case "ping": result = [:]
        case "tools/list": result = ["tools": Self.definitions]
        case "tools/call":
            guard let name = params["name"] as? String else {
                return encode(self.error(id: id, code: -32602, message: "name is required"))
            }
            guard Self.definitions.contains(where: { $0["name"] as? String == name }) else {
                return encode(self.error(id: id, code: -32602, message: "Unknown tool: \(name)"))
            }
            do {
                guard params["arguments"] == nil || params["arguments"] is [String: Any] else { throw PolarisError.invalidInput("argumentsはオブジェクトです") }
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                try validate(name: name, arguments: arguments)
                let value = try call(name, arguments)
                result = ["content": [["type": "text", "text": encode(value)]], "isError": false]
            } catch {
                result = ["content": [["type": "text", "text": error.localizedDescription]], "isError": true]
            }
        default: return encode(self.error(id: id, code: -32601, message: "Method not found"))
        }
        return encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func call(_ name: String, _ a: [String: Any]) throws -> Any {
        switch name {
        case "polaris_get_today":
            let s = try store.read()
            return ["date": s.today.date, "mode": try json(s.today.mode), "northStar": s.today.northStar,
                    "now": try json(s.today.now), "done": try json(s.today.done), "note": s.today.note as Any? ?? NSNull(),
                    "laterCount": s.later.count, "banner": try s.banner.map { try json($0) } ?? NSNull(), "revision": s.revision]
        case "polaris_set_north_star": return try json(store.setNorthStar(a["text"] as! String).today)
        case "polaris_set_mode": return try json(store.setMode(a["mode_id"] as! String).today.mode)
        case "polaris_list_modes": return try json(store.read().availableModes)
        case "polaris_add_task":
            return try json(store.addTask(title: a["title"] as! String, to: TaskDestination(rawValue: a["to"] as? String ?? "later")!, position: integer(a["position"]), source: "mcp:\(clientName)"))
        case "polaris_complete_task": return try json(store.completeTask(id: try uuid(a)).today)
        case "polaris_move_task": return try json(store.moveTask(id: try uuid(a), to: TaskDestination(rawValue: a["to"] as! String)!, position: integer(a["position"])))
        case "polaris_remove_task": return try json(store.removeTask(id: try uuid(a)).today)
        case "polaris_rename_task": return try json(store.renameTask(id: try uuid(a), title: a["title"] as! String).today)
        case "polaris_list_later": return try json(store.read().later)
        case "polaris_nudge": return try json(store.nudge(text: a["text"] as! String, from: clientName, ttlMinutes: (a["ttl_minutes"] as? NSNumber)?.doubleValue ?? 5).banner)
        case "polaris_get_history": return try json(store.history(days: integer(a["days"]) ?? 90))
        default: throw PolarisError.invalidInput("未知のツール: \(name)")
        }
    }
    private func uuid(_ arguments: [String: Any]) throws -> UUID {
        guard let text = arguments["id"] as? String, let id = UUID(uuidString: text) else { throw PolarisError.invalidInput("idはUUIDです") }
        return id
    }
    private func integer(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite, n.doubleValue.rounded() == n.doubleValue,
              n.doubleValue >= 0, n.doubleValue < Double(Int.max) else { return nil }
        return n.intValue
    }
    private func validate(name: String, arguments: [String: Any]) throws {
        guard let definition = Self.definitions.first(where: { $0["name"] as? String == name }),
              let schema = definition["inputSchema"] as? [String: Any], let properties = schema["properties"] as? [String: [String: Any]] else { throw PolarisError.invalidInput("未知のツール: \(name)") }
        for required in schema["required"] as? [String] ?? [] where arguments[required] == nil { throw PolarisError.invalidInput("\(required)が必要です") }
        for (key, value) in arguments {
            guard let property = properties[key] else { throw PolarisError.invalidInput("未知の引数: \(key)") }
            let type = property["type"] as? String
            if type == "string" && !(value is String) { throw PolarisError.invalidInput("\(key)は文字列です") }
            if let max = property["maxLength"] as? Int, let text = value as? String, text.count > max {
                throw PolarisError.invalidInput("\(key)は\(max)文字以内です")
            }
            if type == "integer" && integer(value) == nil { throw PolarisError.invalidInput("\(key)は0以上の整数です") }
            if type == "number" {
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { throw PolarisError.invalidInput("\(key)は数値です") }
            }
            if let options = property["enum"] as? [String], !options.contains(value as? String ?? "") { throw PolarisError.invalidInput("\(key)の値が不正です") }
        }
    }
    private func validID(_ value: Any) -> Bool {
        value is NSNull || value is String || ((value as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() } ?? false)
    }
    private func json<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(value), options: [.fragmentsAllowed])
    }
    private func error(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }
    private func encode(_ value: Any) -> String {
        // All values originate from validated JSON or Foundation's JSONEncoder.
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }

    private static var definitions: [[String: Any]] {
        let caution = " ユーザーの集中を守る道具なのでnowを勝手に入れ替えない。追加はlaterを既定にする。"
        let title: [String: Any] = ["type": "string", "minLength": 1, "maxLength": TextRules.titleMax]
        let id: [String: Any] = ["type": "string", "format": "uuid"]
        let destination: [String: Any] = ["type": "string", "enum": ["now", "later"], "default": "later"]
        let position: [String: Any] = ["type": "integer", "minimum": 0, "description": "0始まり。省略時は末尾。範囲を超える位置は末尾。now満杯ならlater末尾。"]
        func tool(_ name: String, _ description: String, _ properties: [String: [String: Any]] = [:], _ required: [String] = []) -> [String: Any] {
            ["name": name, "description": description + caution, "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false]]
        }
        return [
            tool("polaris_get_today", "今日のモード、北極星、now、done、later件数、bannerを取得する。"),
            tool("polaris_set_north_star", "北極星を1文で設定する。空文字で消去。", ["text": ["type": "string", "maxLength": TextRules.northStarMax]], ["text"]),
            tool("polaris_set_mode", "今日のモードを選ぶ。mode_idはpolaris_list_modesのid。", ["mode_id": ["type": "string", "minLength": 1]], ["mode_id"]),
            tool("polaris_list_modes", "設定で編集したモード一覧を取得する。先頭が既定モード。"),
            tool("polaris_add_task", "タスクを追加する。nowは最大3件。満杯ならlaterへ送りoverflowedで返す。", ["title": title, "to": destination, "position": position], ["title"]),
            tool("polaris_complete_task", "タスクを完了し本命なら次を繰り上げる。", ["id": id], ["id"]),
            tool("polaris_move_task", "指定タスクを移動する。doneからの移動は未完了に戻す。", ["id": id, "to": destination, "position": position], ["id", "to"]),
            tool("polaris_remove_task", "指定タスクを削除する。", ["id": id], ["id"]),
            tool("polaris_rename_task", "指定タスクの名前だけを変える。idと位置は変わらない。", ["id": id, "title": title], ["id", "title"]),
            tool("polaris_list_later", "あとでの一覧を取得する。"),
            tool("polaris_nudge", "一時メッセージを1件表示し以前のメッセージを置換する。", ["text": ["type": "string", "minLength": 1, "maxLength": TextRules.bannerMax], "ttl_minutes": ["type": "number", "exclusiveMinimum": 0, "maximum": 1440, "default": 5]], ["text"]),
            tool("polaris_get_history", "直近90日以内から最大days件の履歴を古い順に取得する。", ["days": ["type": "integer", "minimum": 1, "maximum": 90, "default": 90]])
        ]
    }
}
