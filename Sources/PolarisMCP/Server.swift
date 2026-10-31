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
    public static func parseErrorResponse() -> String {
        #"{"error":{"code":-32700,"message":"Parse error"},"id":null,"jsonrpc":"2.0"}"#
    }
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
            let supported = ["2024-11-05", "2025-06-18"]
            result = ["protocolVersion": supported.contains(version) ? version : "2025-06-18",
                      "capabilities": ["tools": ["listChanged": false]],
                      "serverInfo": ["name": "polaris", "version": PolarisVersion.current]]
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
                    "northStarID": s.today.star?.id.uuidString as Any? ?? NSNull(),
                    "northStarQueue": try json(s.queuedStars),
                    "note": s.today.note as Any? ?? NSNull(),
                    "banner": try s.banner.map { try json($0) } ?? NSNull(), "revision": s.revision]
        case "polaris_set_north_star": return try dayJSON(store.setNorthStar(a["text"] as! String).today)
        case "polaris_list_north_stars":
            let s = try store.read()
            return ["active": try s.today.star.map { try json($0) } ?? NSNull(),
                    "queue": try json(s.queuedStars), "pastCount": s.pastStars.count]
        case "polaris_add_north_star":
            return try json(store.addNorthStar(text: a["text"] as! String, position: integer(a["position"]),
                                              dueDate: a["dueDate"] as? String, startsAt: try optionalDate(a["startsAt"])))
        case "polaris_update_north_star":
            let id = try uuid(a)
            let dueDate: String?? = a.keys.contains("dueDate")
                ? .some(try optionalString(a["dueDate"], label: "dueDate")) : .none
            let startsAt: Date?? = a.keys.contains("startsAt")
                ? .some(try optionalDate(a["startsAt"])) : .none
            let text: String? = try {
                guard a.keys.contains("text") else { return nil }
                guard let text = a["text"] as? String else { throw PolarisError.invalidInput("textは文字列です") }
                return text
            }()
            return try json(store.updateNorthStar(id: id, text: text, dueDate: dueDate, startsAt: startsAt))
        case "polaris_complete_north_star":
            let outcome = (a["outcome"] as? String).flatMap(NorthStarOutcome.init(rawValue:)) ?? .achieved
            let id = try a.keys.contains("id") ? uuid(a) : nil
            let result = try store.completeNorthStar(id: id, outcome: outcome)
            return ["completed": try json(result.completed), "next": try result.next.map { try json($0) } ?? NSNull()]
        case "polaris_switch_north_star": return try dayJSON(store.activateNorthStar(id: try uuid(a)).today)
        case "polaris_remove_north_star": return try json(store.removeNorthStar(id: try uuid(a)).queuedStars)
        case "polaris_get_north_star_log":
            return try json(store.northStarLog(limit: integer(a["limit"]) ?? 30))
        case "polaris_set_mode": return try json(store.setMode(a["mode_id"] as! String).today.mode)
        case "polaris_list_modes": return try json(store.read().availableModes)
        case "polaris_nudge": return try json(store.nudge(text: a["text"] as! String, from: TextRules.clientName("MCP: \(clientName)"), ttlMinutes: (a["ttl_minutes"] as? NSNumber)?.doubleValue ?? 5).banner)
        case "polaris_get_history": return try store.history(days: integer(a["days"]) ?? 90).map { try dayJSON($0) }
        default: throw PolarisError.invalidInput("未知のツール: \(name)")
        }
    }
    /// Core の互換フィールドは MCP には公開しない。
    private func dayJSON(_ day: Day) throws -> [String: Any] {
        guard var value = try json(day) as? [String: Any] else {
            throw PolarisError.invalidState("日ごとの状態を返せない")
        }
        for key in ["now", "done", "later"] { value.removeValue(forKey: key) }
        return value
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
    /// キーがある前提。null なら nil、文字列ならその値。それ以外はエラー。
    private func optionalString(_ value: Any?, label: String) throws -> String? {
        if value == nil || value is NSNull { return nil }
        guard let text = value as? String else { throw PolarisError.invalidInput("\(label)は文字列かnullです") }
        return text
    }
    /// ISO 8601（タイムゾーン付き）。null / 省略は nil。
    private func optionalDate(_ value: Any?) throws -> Date? {
        if value == nil || value is NSNull { return nil }
        guard let text = value as? String else { throw PolarisError.invalidInput("startsAtはISO 8601です") }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: text) else { throw PolarisError.invalidInput("startsAtはISO 8601です") }
        return date
    }
    private func validate(name: String, arguments: [String: Any]) throws {
        guard let definition = Self.definitions.first(where: { $0["name"] as? String == name }),
              let schema = definition["inputSchema"] as? [String: Any], let properties = schema["properties"] as? [String: [String: Any]] else { throw PolarisError.invalidInput("未知のツール: \(name)") }
        for required in schema["required"] as? [String] ?? [] where arguments[required] == nil { throw PolarisError.invalidInput("\(required)が必要です") }
        for (key, value) in arguments {
            guard let property = properties[key] else { throw PolarisError.invalidInput("未知の引数: \(key)") }
            let types: [String]
            if let list = property["type"] as? [String] { types = list }
            else if let single = property["type"] as? String { types = [single] }
            else { types = [] }
            if value is NSNull {
                guard types.contains("null") else { throw PolarisError.invalidInput("\(key)はnullにできません") }
                continue
            }
            let primary = types.first { $0 != "null" }
            if primary == "string" && !(value is String) { throw PolarisError.invalidInput("\(key)は文字列です") }
            if let max = property["maxLength"] as? Int, let text = value as? String, (text.count > max || text.unicodeScalars.count > max) {
                throw PolarisError.invalidInput("\(key)は\(max)文字以内です")
            }
            if primary == "integer" && integer(value) == nil { throw PolarisError.invalidInput("\(key)は0以上の整数です") }
            if primary == "number" {
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { throw PolarisError.invalidInput("\(key)は数値です") }
            }
            if let options = property["enum"] as? [String], !options.contains(value as? String ?? "") { throw PolarisError.invalidInput("\(key)の値が不正です") }
        }
    }
    private func validID(_ value: Any) -> Bool {
        if value is String { return true }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number.doubleValue.isFinite && number.doubleValue.rounded() == number.doubleValue
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
        let caution = " 今日の北極星を1つに絞り、ユーザーの集中を守る道具。"
        let id: [String: Any] = ["type": "string", "format": "uuid"]
        let starText: [String: Any] = ["type": "string", "maxLength": TextRules.northStarMax]
        let starPosition: [String: Any] = ["type": "integer", "minimum": 0, "description": "0始まり。省略時は末尾。範囲を超える位置は末尾。"]
        let dueDate: [String: Any] = ["type": "string", "description": "期限。ローカル時刻のyyyy-MM-dd（その日の終わりまで）かyyyy-MM-ddTHH:mm。"]
        let dueDateOrNull: [String: Any] = ["type": ["string", "null"], "description": "期限。ローカル時刻のyyyy-MM-dd（その日の終わりまで）かyyyy-MM-ddTHH:mm。nullで消す。"]
        let startsAt: [String: Any] = ["type": "string", "description": "控えが自動で今日の北極星に上がる日時。ISO 8601（タイムゾーン付き）。省略時は手動。"]
        let startsAtOrNull: [String: Any] = ["type": ["string", "null"], "description": "控えが自動で今日の北極星に上がる日時。ISO 8601（タイムゾーン付き）。nullで消す（手動に戻す）。"]
        func tool(_ name: String, _ description: String, _ properties: [String: [String: Any]] = [:], _ required: [String] = []) -> [String: Any] {
            ["name": name, "description": description + caution, "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false]]
        }
        return [
            tool("polaris_get_today", "今日のモード、北極星、控え、bannerを取得する。"),
            tool("polaris_set_north_star", "今日の北極星の文面を設定する。空文字なら控えの先頭へ戻す。", ["text": starText], ["text"]),
            tool("polaris_list_north_stars", "今日の北極星、控え、終わった件数を取得する。"),
            tool("polaris_add_north_star", "北極星を控えに追加する。最大20件。dueDateはその日までの期限。startsAtを付けるとその日時に自動で今日の北極星へ上がる予約になる。",
                 ["text": starText.merging(["minLength": 1]) { $1 }, "position": starPosition, "dueDate": dueDate, "startsAt": startsAt], ["text"]),
            tool("polaris_update_north_star", "北極星の文面・期限・予約を更新する。キーが無ければ据え置き、dueDate/startsAtがnullなら消す。startsAtは控えだけに付けられる。",
                 ["id": id, "text": starText.merging(["minLength": 1]) { $1 }, "dueDate": dueDateOrNull, "startsAt": startsAtOrNull], ["id"]),
            tool("polaris_complete_north_star", "今日の北極星を終え、控えのうち予約なしまたは開始時刻を過ぎた最初の星を今日にする。未来予約の星は飛ばす。任意のidを指定すると今日の星と一致する場合だけ終える。不一致なら変更せずエラー。連続実行による次の星の終了を防ぐにはidを指定する。",
                 ["id": id, "outcome": ["type": "string", "enum": ["achieved", "dropped"], "default": "achieved"]]),
            tool("polaris_switch_north_star", "控えの北極星を今日にする。元の今日は控えの先頭へ。予約（startsAt）は消える。", ["id": id], ["id"]),
            tool("polaris_remove_north_star", "控えから北極星を削除する。ログには残さない。", ["id": id], ["id"]),
            tool("polaris_get_north_star_log", "終わった北極星を新しい順に取得する。",
                 ["limit": ["type": "integer", "minimum": 1, "maximum": 500, "default": 30]]),
            tool("polaris_set_mode", "今日のモードを選ぶ。mode_idはpolaris_list_modesのid。", ["mode_id": ["type": "string", "minLength": 1]], ["mode_id"]),
            tool("polaris_list_modes", "設定で編集したモード一覧を取得する。先頭が既定モード。"),
            tool("polaris_nudge", "一時メッセージを1件表示し以前のメッセージを置換する。", ["text": ["type": "string", "minLength": 1, "maxLength": TextRules.bannerMax], "ttl_minutes": ["type": "number", "exclusiveMinimum": 0, "maximum": 1440, "default": 5]], ["text"]),
            tool("polaris_get_history", "直近90日以内から最大days件の履歴を古い順に取得する。", ["days": ["type": "integer", "minimum": 1, "maximum": 90, "default": 90]])
        ]
    }
}
