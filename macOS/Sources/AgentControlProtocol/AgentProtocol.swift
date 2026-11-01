import Foundation

/// Line-delimited JSON over a private Unix socket. One request line, one response line.
/// Times are `ProcessInfo.systemUptime` seconds of the app's machine.
public enum AgentProtocol {
    public static let version = 1
    public static let maxLineBytes = 64 * 1024
    public static let holdRange = 1...60_000
    public static let snapshotWidthRange = 320...3840
    public static let defaultSnapshotWidth = 1280
    /// Same names and order as the Pi's binary input payload.
    public static let buttons = ["A", "B", "X", "Y", "L", "R", "ZL", "ZR", "PLUS", "MINUS", "HOME", "CAPTURE",
                                 "L_STICK_PRESS", "R_STICK_PRESS", "DPAD_UP", "DPAD_DOWN", "DPAD_LEFT", "DPAD_RIGHT"]
    public static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/switch-remote", isDirectory: true)
    }
    public static var defaultSocketPath: String { supportDirectory.appendingPathComponent("agent.sock").path }
    public static var defaultSnapshotDirectory: URL { supportDirectory.appendingPathComponent("agent/snapshots", isDirectory: true) }
    /// `sockaddr_un.sun_path` holds 104 bytes including the terminating NUL.
    public static func socketPathFits(_ path: String) -> Bool { path.utf8.count < 104 }
}

public enum AgentErrorCode: String, Sendable {
    case badRequest = "bad_request", unknownCommand = "unknown_command", notConnected = "not_connected"
    case captureStopped = "capture_stopped", noFrame = "no_frame", busy = "busy", `internal` = "internal"
}

public struct AgentError: Error, Equatable, Sendable {
    public let code: AgentErrorCode
    public let message: String
    public init(_ code: AgentErrorCode, _ message: String) { self.code = code; self.message = message }
}

/// Validated `input` arguments. Axes are finite in -1...1, buttons unique and known.
public struct AgentInputArgs: Equatable, Sendable {
    public var buttons: [String]
    public var lx, ly, rx, ry: Double
    public var holdMs: Int
    public init(buttons: [String] = [], lx: Double = 0, ly: Double = 0, rx: Double = 0, ry: Double = 0, holdMs: Int = 100) {
        self.buttons = buttons; self.lx = lx; self.ly = ly; self.rx = rx; self.ry = ry; self.holdMs = holdMs
    }

    public static func parse(_ args: [String: Any]) throws -> AgentInputArgs {
        var result = AgentInputArgs()
        if let raw = args["buttons"] {
            guard let names = raw as? [Any] else { throw AgentError(.badRequest, "buttons must be an array of strings") }
            var seen = Set<String>()
            for item in names {
                guard let name = item as? String, AgentProtocol.buttons.contains(name) else {
                    throw AgentError(.badRequest, "unknown button; allowed: " + AgentProtocol.buttons.joined(separator: ","))
                }
                if seen.insert(name).inserted { result.buttons.append(name) }
            }
        }
        for key in ["lx", "ly", "rx", "ry"] {
            guard let raw = args[key] else { continue }
            guard let value = AgentJSON.number(raw), value.isFinite, (-1...1).contains(value) else {
                throw AgentError(.badRequest, "\(key) must be a number in -1...1")
            }
            switch key { case "lx": result.lx = value; case "ly": result.ly = value; case "rx": result.rx = value; default: result.ry = value }
        }
        if let raw = args["holdMs"] {
            guard let value = AgentJSON.integer(raw), AgentProtocol.holdRange.contains(value) else {
                throw AgentError(.badRequest, "holdMs must be an integer in \(AgentProtocol.holdRange.lowerBound)...\(AgentProtocol.holdRange.upperBound)")
            }
            result.holdMs = value
        }
        return result
    }

    public var json: [String: Any] { ["buttons": buttons, "lx": lx, "ly": ly, "rx": rx, "ry": ry, "holdMs": holdMs] }
}

public enum AgentJSON {
    /// JSON numbers only; booleans are rejected.
    public static func number(_ value: Any) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }
    public static func integer(_ value: Any) -> Int? {
        guard let double = number(value), double.isFinite, double == double.rounded(), abs(double) < 1e15 else { return nil }
        return Int(double)
    }
    /// One compact JSON object followed by a newline.
    public static func line(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes, .sortedKeys]))
            ?? Data(#"{"ok":false,"error":{"code":"internal","message":"encode failed"}}"#.utf8)
        data.append(10)
        return data
    }
    public static func string(_ object: [String: Any]) -> String {
        String(decoding: line(object).dropLast(), as: UTF8.self)
    }
    public static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    public static func success(id: Any?, result: [String: Any]) -> [String: Any] {
        ["v": AgentProtocol.version, "id": id ?? NSNull(), "ok": true, "result": result]
    }
    public static func failure(id: Any?, _ error: AgentError) -> [String: Any] {
        ["v": AgentProtocol.version, "id": id ?? NSNull(), "ok": false, "error": ["code": error.code.rawValue, "message": error.message]]
    }
}
