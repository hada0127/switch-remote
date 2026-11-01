import AgentControlProtocol
import Foundation

/// MCP over stdio: newline-delimited JSON-RPC 2.0. Logs go to stderr only.
struct MCPServer {
    let commands: Commands
    /// Only versions this server fully implements (no JSON-RPC batches, which 2025-03-26 requires).
    static let supportedVersions = ["2025-06-18"]
    static let snapshotWidth = 960

    struct RPCError: Error { let code: Int; let message: String }

    static var tools: [[String: Any]] {
        let buttons: [String: Any] = ["type": "array", "items": ["type": "string", "enum": AgentProtocol.buttons], "uniqueItems": true]
        let hold: [String: Any] = ["type": "integer", "minimum": AgentProtocol.holdRange.lowerBound, "maximum": AgentProtocol.holdRange.upperBound, "default": 100,
                                   "description": "How long to hold, in ms. A new call replaces the current hold without releasing in between."]
        let gap: [String: Any] = ["type": "integer", "minimum": 0, "maximum": 60_000, "default": 60, "description": "Extra wait after the hold ends, in ms."]
        let wait: [String: Any] = ["type": "boolean", "default": false,
                                   "description": "Default false: return as soon as the hold starts, so inputs chain (continuous movement) and switch_release stays responsive. True waits for hold + gap, so the next command cannot merge into this hold."]
        func axis(_ text: String) -> [String: Any] { ["type": "number", "minimum": -1, "maximum": 1, "default": 0, "description": text] }
        func tool(_ name: String, _ description: String, _ properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
            ["name": name, "description": description,
             "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false] as [String: Any]]
        }
        return [
            tool("switch_status", "Read switch-remote state: capture running and frame age, Pi/Switch link, transport, input RTT, current agent hold."),
            tool("switch_snapshot", "Capture the current Nintendo Switch screen (raw capture-card frame, before effects) as a PNG image.",
                 ["maxWidth": ["type": "integer", "minimum": AgentProtocol.snapshotWidthRange.lowerBound, "maximum": AgentProtocol.snapshotWidthRange.upperBound, "default": snapshotWidth] as [String: Any]]),
            tool("switch_press", "Press buttons together on the Switch controller, hold for holdMs, then release. Returns immediately unless wait is true; wait at least holdMs + gapMs before pressing the same buttons again.",
                 ["buttons": buttons.merging(["minItems": 1]) { $1 }, "holdMs": hold, "gapMs": gap, "wait": wait], required: ["buttons"]),
            tool("switch_input", "Send buttons and stick positions (ly/ry positive is up) held for holdMs, then neutral. Returns immediately unless wait is true; a new input before the hold ends replaces it without a release in between.",
                 ["buttons": buttons, "lx": axis("Left stick X"), "ly": axis("Left stick Y"), "rx": axis("Right stick X"), "ry": axis("Right stick Y"),
                  "holdMs": hold, "gapMs": gap, "wait": wait]),
            tool("switch_release", "Release every agent-held button and stick now."),
            tool("switch_controller_disconnect", "Release inputs and detach the Pi USB controller from the Switch."),
            tool("switch_controller_reconnect", "Reattach the Pi USB controller to the Switch."),
            tool("switch_source", "Select controller source. None releases input and detaches USB; gamepad or Moonlight reattaches USB.",
                 ["source": ["type": "string", "enum": ["none", "gamepad", "moonlight"]] as [String: Any]], required: ["source"])
        ]
    }

    func run() {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let response = handle(line) { FileHandle.standardOutput.write(AgentJSON.line(response)) }
        }
    }

    /// MCP ids are strings or JSON integer tokens. Booleans, null and any number written with a
    /// fraction or exponent (even 1.0) are rejected. Integer ids have no size limit and are echoed unchanged.
    static func validID(_ value: Any) -> Bool {
        if value is String { return true }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return !CFNumberIsFloatType(number)
    }

    /// Returns nil only for a valid notification.
    func handle(_ line: String) -> [String: Any]? {
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(line.utf8), options: [.fragmentsAllowed]) else {
            return error(id: nil, RPCError(code: -32700, message: "parse error"))
        }
        guard let message = parsed as? [String: Any] else { return error(id: nil, RPCError(code: -32600, message: "invalid request: expected one JSON object (batches are not supported)")) }
        let hasID = message.keys.contains("id")
        let id: Any? = hasID ? message["id"] : nil
        if let id, !Self.validID(id) { return error(id: nil, RPCError(code: -32600, message: "invalid request: id must be a string or integer")) }
        guard message["jsonrpc"] as? String == "2.0", let method = message["method"] as? String else {
            return error(id: id, RPCError(code: -32600, message: "invalid request"))
        }
        if let raw = message["params"], !(raw is [String: Any]) {
            return hasID ? error(id: id, RPCError(code: -32602, message: "params must be an object")) : error(id: nil, RPCError(code: -32600, message: "invalid notification: params must be an object"))
        }
        guard let id else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        do {
            let result: [String: Any]
            switch method {
            case "initialize":
                guard let requested = params["protocolVersion"] as? String, params["capabilities"] is [String: Any],
                      let client = params["clientInfo"] as? [String: Any], client["name"] is String, client["version"] is String else {
                    throw RPCError(code: -32602, message: "initialize needs protocolVersion, capabilities and clientInfo {name, version}")
                }
                result = ["protocolVersion": Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[0],
                          "capabilities": ["tools": ["listChanged": false]],
                          "serverInfo": ["name": "switchctl", "version": "1.0.0"]]
            case "ping": result = [:]
            case "tools/list": result = ["tools": Self.tools]
            case "tools/call": result = try call(params)
            default: throw RPCError(code: -32601, message: "method not found: \(method)")
            }
            return ["jsonrpc": "2.0", "id": id, "result": result]
        } catch let rpc as RPCError {
            return error(id: id, rpc)
        } catch {
            return self.error(id: id, RPCError(code: -32603, message: "\(error)"))
        }
    }

    private func error(id: Any?, _ error: RPCError) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": error.code, "message": error.message]]
    }

    private func text(_ object: [String: Any], isError: Bool) -> [String: Any] {
        ["content": [["type": "text", "text": AgentJSON.string(object)]], "isError": isError]
    }

    private func call(_ params: [String: Any]) throws -> [String: Any] {
        guard let name = params["name"] as? String else { throw RPCError(code: -32602, message: "missing tool name") }
        let rawArguments = params["arguments"] ?? [String: Any]()
        guard let arguments = rawArguments as? [String: Any] else { throw RPCError(code: -32602, message: "arguments must be an object") }
        func allow(_ keys: Set<String>) throws {
            if let extra = arguments.keys.first(where: { !keys.contains($0) }) { throw RPCError(code: -32602, message: "unknown argument \(extra)") }
        }
        func integer(_ key: String, default value: Int, range: ClosedRange<Int>) throws -> Int {
            guard let raw = arguments[key] else { return value }
            guard let parsed = AgentJSON.integer(raw), range.contains(parsed) else { throw RPCError(code: -32602, message: "\(key) must be an integer in \(range.lowerBound)...\(range.upperBound)") }
            return parsed
        }
        func flag(_ key: String) throws -> Bool {
            guard let raw = arguments[key] else { return false }
            guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw RPCError(code: -32602, message: "\(key) must be a boolean") }
            return number.boolValue
        }
        let outcome: Outcome
        switch name {
        case "switch_status":
            try allow([]); outcome = commands.status()
        case "switch_release":
            try allow([]); outcome = commands.release()
        case "switch_controller_disconnect", "switch_controller_reconnect":
            try allow([]); outcome = commands.controller(name == "switch_controller_disconnect" ? "detach" : "attach")
        case "switch_source":
            try allow(["source"])
            guard let source = arguments["source"] as? String, ["none", "gamepad", "moonlight"].contains(source) else { throw RPCError(code: -32602, message: "source must be none, gamepad or moonlight") }
            outcome = commands.source(source)
        case "switch_snapshot":
            try allow(["maxWidth"])
            let width = try integer("maxWidth", default: Self.snapshotWidth, range: AgentProtocol.snapshotWidthRange)
            outcome = commands.snapshot(maxWidth: width, out: nil)
            if outcome.ok, let result = outcome.result, let path = result["path"] as? String {
                guard let png = FileManager.default.contents(atPath: path) else { return text(["error": "cannot read snapshot file"], isError: true) }
                return ["content": [["type": "image", "mimeType": "image/png", "data": png.base64EncodedString()],
                                    ["type": "text", "text": AgentJSON.string(result)]], "isError": false]
            }
        case "switch_press", "switch_input":
            let press = name == "switch_press"
            try allow(press ? ["buttons", "holdMs", "gapMs", "wait"] : ["buttons", "lx", "ly", "rx", "ry", "holdMs", "gapMs", "wait"])
            if press { guard let buttons = arguments["buttons"] as? [Any], !buttons.isEmpty else { throw RPCError(code: -32602, message: "buttons must be a non-empty array") } }
            let parsed: AgentInputArgs
            do { parsed = try AgentInputArgs.parse(arguments.filter { ["buttons", "lx", "ly", "rx", "ry", "holdMs"].contains($0.key) }) }
            catch let error as AgentError { throw RPCError(code: -32602, message: error.message) }
            let gap = try integer("gapMs", default: 60, range: 0...60_000)
            outcome = commands.input(parsed, gapMs: gap, wait: try flag("wait"))
        default:
            throw RPCError(code: -32602, message: "unknown tool \(name)")
        }
        return outcome.ok ? text(outcome.result ?? [:], isError: false) : text(outcome.json, isError: true)
    }
}
