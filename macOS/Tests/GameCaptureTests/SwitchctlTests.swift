import XCTest
import AgentControlProtocol
@testable import GameCapture

/// Runs the built `switchctl` binary against the real socket server with a fake host.
final class SwitchctlTests: XCTestCase {
    private var root: URL!
    private var socketPath: String { root.appendingPathComponent("agent.sock").path }
    private var binary: URL { Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("switchctl") }

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sc-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary.path), binary.path)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func start(_ fake: FakeAgentHost) throws -> AgentControlServer {
        let server = AgentControlServer(socketPath: socketPath, snapshotDirectory: root.appendingPathComponent("snapshots"), host: fake.host, hostQueue: fake.queue)
        try server.start()
        return server
    }

    private func run(_ arguments: [String], stdin: String? = nil) throws -> (code: Int32, lines: [[String: Any]], seconds: Double) {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--socket", socketPath] + arguments
        let output = Pipe(), input = Pipe()
        process.standardOutput = output; process.standardError = FileHandle.nullDevice; process.standardInput = input
        let started = Date()
        try process.run()
        if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let lines = data.split(separator: 10).map { AgentJSON.object(Data($0)) ?? ["unparsed": String(decoding: $0, as: UTF8.self)] }
        return (process.terminationStatus, lines, Date().timeIntervalSince(started))
    }

    func testExitCodes() throws {
        let missing = try run(["status"])
        XCTAssertEqual(missing.code, 3); XCTAssertEqual(missing.lines.count, 1)
        XCTAssertEqual(try run(["bogus"]).code, 2)
        XCTAssertEqual(try run(["press"]).code, 2)
        XCTAssertEqual(try run(["press", "TURBO"]).code, 2)
        XCTAssertEqual(try run(["input", "--lx", "2"]).code, 2)
        XCTAssertEqual(try run(["input", "--hold-ms", "60001"]).code, 2)
        XCTAssertEqual(try run(["snapshot", "--max-width", "10"]).code, 2)
        XCTAssertEqual(try run(["source", "invalid"]).code, 2)

        let fake = FakeAgentHost(); fake.frame = AgentControlServerTests.bgra(width: 1280, height: 720)
        let server = try start(fake); defer { server.stop() }
        let status = try run(["status"])
        XCTAssertEqual(status.code, 0); XCTAssertEqual(status.lines.count, 1)
        XCTAssertEqual(status.lines[0]["ok"] as? Bool, true)
        XCTAssertEqual(try run(["release"]).code, 0)
        let source = try run(["source", "none"])
        XCTAssertEqual((source.lines[0]["result"] as? [String: Any])?["source"] as? String, "none")
        let out = root.appendingPathComponent("copy.png").path
        let snapshot = try run(["snapshot", "--max-width", "320", "--out", out])
        XCTAssertEqual(snapshot.code, 0)
        XCTAssertEqual((snapshot.lines[0]["result"] as? [String: Any])?["out"] as? String, out)
        XCTAssertNotNil(NSImage(contentsOfFile: out))

        fake.lock.lock(); fake.connected = false; fake.lock.unlock()
        let refused = try run(["press", "B", "--no-wait"])
        XCTAssertEqual(refused.code, 4)
        XCTAssertEqual((refused.lines[0]["error"] as? [String: Any])?["code"] as? String, "not_connected")
    }

    func testPressWaitsForHoldPlusGapAndNoWaitChains() throws {
        let fake = FakeAgentHost()
        let server = try start(fake); defer { server.stop() }
        let press = try run(["press", "dpad_right,B", "--hold-ms", "150", "--gap-ms", "60"])
        XCTAssertEqual(press.code, 0)
        XCTAssertGreaterThanOrEqual(press.seconds, 0.21)
        XCTAssertEqual(fake.inputs.last, AgentInputArgs(buttons: ["DPAD_RIGHT", "B"], holdMs: 150))

        let chained = try run(["input", "--lx", "1", "--hold-ms", "60000", "--no-wait"])
        XCTAssertEqual(chained.code, 0)
        XCTAssertLessThan(chained.seconds, 5)
        XCTAssertEqual(fake.inputs.last, AgentInputArgs(lx: 1, holdMs: 60_000))
    }

    func testMCPRoundTrip() throws {
        let fake = FakeAgentHost(); fake.frame = AgentControlServerTests.bgra(width: 1920, height: 1080)
        let server = try start(fake); defer { server.stop() }
        let script = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"0"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"switch_snapshot","arguments":{}}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"switch_press","arguments":{"buttons":["HOME"],"holdMs":20,"gapMs":0}}}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"switch_input","arguments":{"lx":2}}}"#,
            #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"no_such_tool"}}"#,
            #"{"jsonrpc":"2.0","id":7,"method":"resources/list"}"#,
            #"{"jsonrpc":"2.0","id":8,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":9,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"old","version":"1"}}}"#,
            "not json"
        ].joined(separator: "\n") + "\n"
        let result = try run(["mcp"], stdin: script)
        XCTAssertEqual(result.code, 0)
        var byID: [Int: [String: Any]] = [:]
        for line in result.lines { if let id = line["id"] as? Int { byID[id] = line } }
        XCTAssertEqual(result.lines.count, 10) // notification gets no reply; parse error gets id null

        XCTAssertEqual((byID[1]?["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-06-18")
        let tools = ((byID[2]?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        XCTAssertEqual(tools, ["switch_status", "switch_snapshot", "switch_press", "switch_input", "switch_release", "switch_controller_disconnect", "switch_controller_reconnect", "switch_source"])

        let snapshot = try XCTUnwrap(byID[3]?["result"] as? [String: Any])
        XCTAssertEqual(snapshot["isError"] as? Bool, false)
        let content = try XCTUnwrap(snapshot["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "image")
        XCTAssertEqual(content.first?["mimeType"] as? String, "image/png")
        let png = try XCTUnwrap(Data(base64Encoded: content.first?["data"] as? String ?? ""))
        let image = try XCTUnwrap(NSImage(data: png)?.representations.first)
        XCTAssertEqual(image.pixelsWide, 960); XCTAssertEqual(image.pixelsHigh, 540)
        XCTAssertEqual(content.last?["type"] as? String, "text")

        XCTAssertEqual((byID[4]?["result"] as? [String: Any])?["isError"] as? Bool, false)
        XCTAssertEqual(fake.inputs.last, AgentInputArgs(buttons: ["HOME"], holdMs: 20))
        XCTAssertEqual((byID[5]?["error"] as? [String: Any])?["code"] as? Int, -32602)
        XCTAssertEqual((byID[6]?["error"] as? [String: Any])?["code"] as? Int, -32602)
        XCTAssertEqual((byID[7]?["error"] as? [String: Any])?["code"] as? Int, -32601)
        XCTAssertNotNil(byID[8]?["result"] as? [String: Any])
        // Only the fully implemented version is offered; 2025-03-26 (batch receive) is not.
        XCTAssertEqual((byID[9]?["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-06-18")
        XCTAssertTrue(result.lines.contains { ($0["error"] as? [String: Any])?["code"] as? Int == -32700 })

        fake.lock.lock(); fake.connected = false; fake.lock.unlock()
        let refused = try run(["mcp"], stdin: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"switch_press","arguments":{"buttons":["B"]}}}"# + "\n")
        XCTAssertEqual((refused.lines.first?["result"] as? [String: Any])?["isError"] as? Bool, true)
    }

    func testMCPDefaultsToNoWait() throws {
        let fake = FakeAgentHost()
        let server = try start(fake); defer { server.stop() }
        let result = try run(["mcp"], stdin: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"switch_input","arguments":{"lx":1,"holdMs":60000}}}"# + "\n")
        XCTAssertEqual((result.lines.first?["result"] as? [String: Any])?["isError"] as? Bool, false)
        XCTAssertLessThan(result.seconds, 10)
        let tools = MCPToolsProbe.descriptions(try run(["mcp"], stdin: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"# + "\n").lines)
        XCTAssertTrue(tools["switch_press"]?.contains("Returns immediately unless wait is true") == true)
        XCTAssertTrue(tools["switch_input"]?.contains("Returns immediately unless wait is true") == true)
    }

    func testMCPEnvelopeValidationNeverReachesHost() throws {
        let fake = FakeAgentHost(); fake.frame = AgentControlServerTests.bgra(width: 64, height: 36)
        let server = try start(fake); defer { server.stop() }
        let press = #""method":"tools/call","params":{"name":"switch_press","arguments":{"buttons":["A"]}}"#
        let cases: [(line: String, code: Int?, id: Any?)] = [
            ("{oops", -32700, nil),
            (#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#, -32600, nil),
            (#"42"#, -32600, nil),
            (#"{}"#, -32600, nil),
            (#"{"jsonrpc":"2.0","id":true,"# + press + "}", -32600, nil),
            (#"{"jsonrpc":"2.0","id":[1],"# + press + "}", -32600, nil),
            (#"{"jsonrpc":"2.0","id":null,"# + press + "}", -32600, nil),
            (#"{"jsonrpc":"2.0","id":1.5,"# + press + "}", -32600, nil),
            (#"{"jsonrpc":"2.0","id":1.0,"# + press + "}", -32600, nil),
            (#"{"jsonrpc":"2.0","id":4503599627370496.5,"# + press + "}", -32600, nil),
            (#"{"jsonrpc":"2.0","id":-4503599627370496.5,"# + press + "}", -32600, nil),
            (#"{"jsonrpc":"2.0","id":1e3,"# + press + "}", -32600, nil),
            (#"{"jsonrpc":"1.0","id":"s","# + press + "}", -32600, "s"),
            (#"{"jsonrpc":"2.0","id":"t","method":7}"#, -32600, "t"),
            (#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":1}"#, -32602, 3),
            (#"{"jsonrpc":"2.0","id":4,"method":"ping","params":[]}"#, -32602, 4),
            (#"{"jsonrpc":"2.0","id":5,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#, -32602, 5),
            (#"{"jsonrpc":"2.0","id":6,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"x"}}}"#, -32602, 6),
            (#"{"jsonrpc":"2.0","method":"notifications/initialized","params":1}"#, -32600, nil),
            (#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, nil, nil),
            (#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#, nil, nil),
            (#"{"jsonrpc":"2.0","id":"ok","method":"ping"}"#, 0, "ok"),
            // Large exact integer ids are valid and echoed unchanged (no argument-size limit).
            (#"{"jsonrpc":"2.0","id":1000000000000000,"method":"ping"}"#, 0, 1_000_000_000_000_000),
            (#"{"jsonrpc":"2.0","id":-1000000000000000,"method":"ping"}"#, 0, -1_000_000_000_000_000),
            (#"{"jsonrpc":"2.0","id":9007199254740991,"method":"ping"}"#, 0, 9_007_199_254_740_991),
            (#"{"jsonrpc":"2.0","id":0,"method":"ping"}"#, 0, 0),
        ]
        let result = try run(["mcp"], stdin: cases.map(\.line).joined(separator: "\n") + "\n")
        XCTAssertEqual(result.code, 0)
        let expected = cases.filter { $0.code != nil }
        XCTAssertEqual(result.lines.count, expected.count)
        for (line, want) in zip(result.lines, expected) {
            if want.code == 0 { XCTAssertNotNil(line["result"], want.line); XCTAssertNil(line["error"], want.line) }
            else { XCTAssertEqual((line["error"] as? [String: Any])?["code"] as? Int, want.code, want.line) }
            switch want.id {
            case nil: XCTAssertTrue(line["id"] is NSNull, want.line)
            case let id as String: XCTAssertEqual(line["id"] as? String, id, want.line)
            case let id as Int:
                XCTAssertEqual(line["id"] as? Int, id, want.line)
                XCTAssertFalse((line["id"] as? NSNumber).map { CFNumberIsFloatType($0) } ?? true, want.line)
            default: XCTFail(want.line)
            }
        }
        XCTAssertEqual(fake.hostCalls, 0)
        XCTAssertTrue(fake.inputs.isEmpty)
    }

    func testSnapshotOutNeverDeletesAndRejectsDirectories() throws {
        let fake = FakeAgentHost(); fake.frame = AgentControlServerTests.bgra(width: 640, height: 360)
        let server = try start(fake); defer { server.stop() }
        let folder = root.appendingPathComponent("keep")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("precious".utf8).write(to: folder.appendingPathComponent("inside.txt"))
        let refused = try run(["snapshot", "--out", folder.path])
        XCTAssertEqual(refused.code, 2)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("inside.txt")), "precious")

        let target = root.appendingPathComponent("shot.png")
        try Data("old".utf8).write(to: target)
        let replaced = try run(["snapshot", "--max-width", "320", "--out", target.path])
        XCTAssertEqual(replaced.code, 0)
        XCTAssertEqual(NSImage(contentsOf: target)?.representations.first?.pixelsWide, 320)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasSuffix(".tmp") })
    }

    func testCopyReplacingKeepsExistingFileOnFailureAndHandlesSamePath() throws {
        let source = root.appendingPathComponent("source.png")
        try Data("new".utf8).write(to: source)
        // Same file (also via a different spelling of the path): no-op, content kept.
        XCTAssertNoThrow(try AgentFiles.copyReplacing(source, to: URL(fileURLWithPath: root.path + "/./source.png")))
        XCTAssertEqual(try String(contentsOf: source), "new")

        // Unwritable destination folder: the copy fails and the existing file is untouched.
        let locked = root.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let existing = locked.appendingPathComponent("shot.png")
        try Data("old".utf8).write(to: existing)
        chmod(locked.path, 0o500)
        defer { chmod(locked.path, 0o700) }
        XCTAssertThrowsError(try AgentFiles.copyReplacing(source, to: existing))
        XCTAssertEqual(try String(contentsOf: existing), "old")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: locked.path), ["shot.png"])

        // Missing source: existing destination kept.
        chmod(locked.path, 0o700)
        XCTAssertThrowsError(try AgentFiles.copyReplacing(root.appendingPathComponent("missing.png"), to: existing))
        XCTAssertEqual(try String(contentsOf: existing), "old")
        XCTAssertThrowsError(try AgentFiles.copyReplacing(source, to: locked)) {
            XCTAssertEqual($0 as? AgentFiles.CopyError, .destinationIsDirectory)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: locked.path), ["shot.png"])
    }
}

enum MCPToolsProbe {
    static func descriptions(_ lines: [[String: Any]]) -> [String: String] {
        let tools = (lines.first?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        return Dictionary(uniqueKeysWithValues: tools.compactMap { tool in
            (tool["name"] as? String).map { ($0, tool["description"] as? String ?? "") }
        })
    }
}
