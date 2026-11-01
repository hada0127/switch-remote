import AgentControlProtocol
import Foundation

/// One finished command: the JSON line for stdout and the process exit code.
struct Outcome {
    var json: [String: Any]
    var exitCode: Int32
    var ok: Bool { exitCode == 0 }

    static func response(_ object: [String: Any]) -> Outcome {
        Outcome(json: object, exitCode: object["ok"] as? Bool == true ? 0 : 4)
    }
    static func local(_ code: String, _ message: String, exit: Int32) -> Outcome {
        Outcome(json: ["ok": false, "error": ["code": code, "message": message]], exitCode: exit)
    }
    static func usage(_ message: String) -> Outcome { local("usage", message, exit: 2) }
    var result: [String: Any]? { json["result"] as? [String: Any] }
}

/// Socket calls shared by the CLI and the MCP server.
struct Commands {
    let socket: String

    func call(_ cmd: String, _ args: [String: Any] = [:]) -> Outcome {
        do { return .response(try AgentClient.request(cmd, args: args, socket: socket)) }
        catch AgentClient.Failure.appNotRunning(let message) { return .local("app_not_running", message, exit: 3) }
        catch AgentClient.Failure.io(let message) { return .local("internal", message, exit: 1) }
        catch { return .local("internal", "\(error)", exit: 1) }
    }

    func status() -> Outcome { call("status") }
    func release() -> Outcome { call("release") }
    func controller(_ action: String) -> Outcome { call("controller", ["action": action]) }
    func source(_ value: String) -> Outcome { call("source", ["source": value]) }

    func snapshot(maxWidth: Int?, out: String?) -> Outcome {
        var outcome = call("snapshot", maxWidth.map { ["maxWidth": $0] } ?? [:])
        guard outcome.ok, let out, var result = outcome.result, let path = result["path"] as? String else { return outcome }
        do {
            result["out"] = try AgentFiles.copyReplacing(URL(fileURLWithPath: path), to: URL(fileURLWithPath: out)).path
            outcome.json["result"] = result
            return outcome
        } catch AgentFiles.CopyError.destinationIsDirectory {
            return .usage("--out must be a file path, not a directory")
        } catch {
            return .local("internal", "cannot copy snapshot: \(error)", exit: 1)
        }
    }

    /// Sends one hold. Unless `wait` is false, returns only after `until + gapMs`, so the
    /// next command cannot merge into this hold or swallow its release edge.
    func input(_ args: AgentInputArgs, gapMs: Int, wait: Bool) -> Outcome {
        let outcome = call("input", args.json)
        guard outcome.ok, wait, let until = outcome.result?["until"] as? Double else { return outcome }
        let delay = until + Double(gapMs) / 1000 - ProcessInfo.processInfo.systemUptime
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        return outcome
    }
}
