import AgentControlProtocol
import Foundation

let usageText = """
usage: switchctl [--socket PATH] <command> [options]
  status
  snapshot [--max-width N] [--out PATH]
  press BTN[,BTN...] [--hold-ms 100] [--gap-ms 60] [--no-wait]
  input [--buttons BTN,...] [--lx F] [--ly F] [--rx F] [--ry F] [--hold-ms 100] [--gap-ms 60] [--no-wait]
  release
  controller disconnect|reconnect
  source none|gamepad|moonlight
  mcp                      MCP stdio server (including switch_source and switch_controller_* tools)
Buttons: \(AgentProtocol.buttons.joined(separator: " "))
Axes are -1...1 (ly/ry: positive is up). hold-ms is 1...60000; a new input replaces the current hold
without a release in between, so --no-wait calls can chain continuous movement.
Socket: --socket, else $SWITCH_REMOTE_SOCKET, else \(AgentProtocol.defaultSocketPath)
stdout is always one JSON line. Exit: 0 ok, 1 internal, 2 usage, 3 app not running, 4 request failed.
"""

struct UsageError: Error { let message: String }

/// Minimal option parser: `--name value` pairs and boolean flags.
struct Options {
    var positional: [String] = []
    var values: [String: String] = [:]
    var flags: Set<String> = []

    init(_ arguments: [String], valued: Set<String>, booleans: Set<String>) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--") {
                let name = String(argument.dropFirst(2))
                if booleans.contains(name) { flags.insert(name) }
                else if valued.contains(name) {
                    guard index + 1 < arguments.count else { throw UsageError(message: "\(argument) needs a value") }
                    values[name] = arguments[index + 1]; index += 1
                } else { throw UsageError(message: "unknown option \(argument)") }
            } else { positional.append(argument) }
            index += 1
        }
    }
    func int(_ name: String, default value: Int) throws -> Int {
        guard let raw = values[name] else { return value }
        guard let parsed = Int(raw) else { throw UsageError(message: "--\(name) must be an integer") }
        return parsed
    }
    func double(_ name: String) throws -> Double? {
        guard let raw = values[name] else { return nil }
        guard let parsed = Double(raw), parsed.isFinite else { throw UsageError(message: "--\(name) must be a number") }
        return parsed
    }
}

func buttonList(_ raw: String) -> [String] {
    raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).uppercased() }.filter { !$0.isEmpty }
}

/// Range checks happen here too so bad arguments are usage errors (exit 2), not request failures.
func validated(_ args: [String: Any]) throws -> AgentInputArgs {
    do { return try AgentInputArgs.parse(args) }
    catch let error as AgentError { throw UsageError(message: error.message) }
}

func run(_ arguments: [String]) -> Outcome {
    var arguments = arguments
    var socketOverride: String?
    if let index = arguments.firstIndex(of: "--socket") {
        guard index + 1 < arguments.count else { return .usage("--socket needs a value") }
        socketOverride = arguments[index + 1]; arguments.removeSubrange(index...(index + 1))
    }
    let commands = Commands(socket: AgentClient.socketPath(socketOverride))
    guard let command = arguments.first else { return .usage("missing command") }
    let rest = Array(arguments.dropFirst())
    do {
        switch command {
        case "status", "release":
            let options = try Options(rest, valued: [], booleans: [])
            guard options.positional.isEmpty else { throw UsageError(message: "\(command) takes no arguments") }
            return command == "status" ? commands.status() : commands.release()
        case "controller":
            let options = try Options(rest, valued: [], booleans: [])
            guard options.positional.count == 1, let action = ["disconnect": "detach", "reconnect": "attach"][options.positional[0]] else { throw UsageError(message: "controller needs disconnect or reconnect") }
            return commands.controller(action)
        case "source":
            let options = try Options(rest, valued: [], booleans: [])
            guard options.positional.count == 1, ["none", "gamepad", "moonlight"].contains(options.positional[0]) else { throw UsageError(message: "source needs none, gamepad or moonlight") }
            return commands.source(options.positional[0])
        case "snapshot":
            let options = try Options(rest, valued: ["max-width", "out"], booleans: [])
            guard options.positional.isEmpty else { throw UsageError(message: "snapshot takes no positional arguments") }
            var width: Int?
            if options.values["max-width"] != nil {
                let value = try options.int("max-width", default: AgentProtocol.defaultSnapshotWidth)
                guard AgentProtocol.snapshotWidthRange.contains(value) else { throw UsageError(message: "--max-width must be in 320...3840") }
                width = value
            }
            if let out = options.values["out"] {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: out, isDirectory: &isDirectory), isDirectory.boolValue {
                    throw UsageError(message: "--out must be a file path, not a directory")
                }
            }
            return commands.snapshot(maxWidth: width, out: options.values["out"])
        case "press", "input":
            let options = try Options(rest, valued: ["hold-ms", "gap-ms", "buttons", "lx", "ly", "rx", "ry"], booleans: ["no-wait"])
            var args: [String: Any] = ["holdMs": try options.int("hold-ms", default: 100)]
            if command == "press" {
                guard options.positional.count == 1 else { throw UsageError(message: "press needs one BTN[,BTN...] argument") }
                guard ["buttons", "lx", "ly", "rx", "ry"].allSatisfy({ options.values[$0] == nil }) else { throw UsageError(message: "press takes buttons only; use input for sticks") }
                args["buttons"] = buttonList(options.positional[0])
                guard !(args["buttons"] as! [String]).isEmpty else { throw UsageError(message: "press needs at least one button") }
            } else {
                guard options.positional.isEmpty else { throw UsageError(message: "input takes options only") }
                if let raw = options.values["buttons"] { args["buttons"] = buttonList(raw) }
                for axis in ["lx", "ly", "rx", "ry"] { if let value = try options.double(axis) { args[axis] = value } }
            }
            let gap = try options.int("gap-ms", default: 60)
            guard (0...60_000).contains(gap) else { throw UsageError(message: "--gap-ms must be in 0...60000") }
            return commands.input(try validated(args), gapMs: gap, wait: !options.flags.contains("no-wait"))
        case "mcp":
            guard rest.isEmpty else { throw UsageError(message: "mcp takes no arguments") }
            MCPServer(commands: commands).run()
            exit(0)
        case "help", "--help", "-h":
            FileHandle.standardError.write(Data((usageText + "\n").utf8))
            return Outcome(json: ["ok": true, "result": ["usage": usageText]], exitCode: 0)
        default:
            throw UsageError(message: "unknown command \(command)")
        }
    } catch let error as UsageError {
        return .usage(error.message)
    } catch {
        return .local("internal", "\(error)", exit: 1)
    }
}

@main enum SwitchCtl {
    static func main() {
        let outcome = run(Array(CommandLine.arguments.dropFirst()))
        if outcome.exitCode == 2 { FileHandle.standardError.write(Data((usageText + "\n").utf8)) }
        FileHandle.standardOutput.write(AgentJSON.line(outcome.json))
        exit(outcome.exitCode)
    }
}
