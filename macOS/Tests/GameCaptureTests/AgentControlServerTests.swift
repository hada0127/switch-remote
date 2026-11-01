import XCTest
import CoreVideo
import Darwin
import AgentControlProtocol
@testable import GameCapture

/// Fake host state shared between the test thread and the host queue.
final class FakeAgentHost: @unchecked Sendable {
    let lock = NSLock()
    var connected = true
    var inputs: [AgentInputArgs] = []
    var releases = 0
    var frame: CVPixelBuffer?
    var gate: DispatchSemaphore?
    let entered = DispatchSemaphore(value: 0)
    var statusGate: DispatchSemaphore?
    let statusEntered = DispatchSemaphore(value: 0)
    var statusCalls = 0
    var hostCalls: Int { lock.lock(); defer { lock.unlock() }; return statusCalls + inputs.count + releases }
    let queue = DispatchQueue(label: "test.agent.host")

    var host: AgentControlHost {
        AgentControlHost(
            status: { [self] in
                lock.lock(); statusCalls += 1; let gate = statusGate; lock.unlock()
                if let gate { statusEntered.signal(); gate.wait() }
                return ["controller": ["connected": true, "transport": "udp-v2"], "agent": ["holdUntil": NSNull()]]
            },
            input: { [self] args in
                lock.lock(); defer { lock.unlock() }
                guard connected else { return .failure(AgentError(.notConnected, "not connected")) }
                inputs.append(args)
                return .success(["forwardedAt": 1.0, "until": ProcessInfo.processInfo.systemUptime + Double(args.holdMs) / 1000])
            },
            release: { [self] in lock.lock(); releases += 1; lock.unlock(); return ["released": true] },
            usb: { action in .success(["requested": action]) },
            source: { source in .success(["source": source]) },
            frame: { [self] in
                lock.lock(); let gate = gate, frame = frame; lock.unlock()
                if let gate { entered.signal(); gate.wait() }
                guard let frame else { return .failure(AgentError(.noFrame, "no frame")) }
                return .success((frame, 7, ProcessInfo.processInfo.systemUptime))
            })
    }
}

final class AgentControlServerTests: XCTestCase {
    private var root: URL!
    private var socketPath: String { root.appendingPathComponent("s/agent.sock").path }
    private var snapshots: URL { root.appendingPathComponent("s/agent/snapshots") }

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sr-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func server(_ fake: FakeAgentHost) throws -> AgentControlServer {
        let server = AgentControlServer(socketPath: socketPath, snapshotDirectory: snapshots, host: fake.host, hostQueue: fake.queue)
        try server.start()
        return server
    }

    static func bgra(width: Int, height: Int) -> CVPixelBuffer {
        var result: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &result)
        let buffer = result!
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 200, CVPixelBufferGetBytesPerRow(buffer) * height)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private func connected() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(socketPath.utf8) + [0]) }
        XCTAssertEqual(withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }, 0)
        var on: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, 4)
        var timeout = timeval(tv_sec: 3, tv_usec: 0); setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    private func readLines(_ fd: Int32, count wanted: Int) -> [[String: Any]] {
        var response = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while response.filter({ $0 == 10 }).count < wanted {
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            response.append(contentsOf: buffer[..<count])
        }
        return response.split(separator: 10).compactMap { AgentJSON.object(Data($0)) }
    }

    /// Sends raw bytes and returns the first response line.
    private func raw(_ bytes: Data) throws -> [String: Any] {
        let fd = connected(); defer { close(fd) }
        _ = bytes.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        return try XCTUnwrap(readLines(fd, count: 1).first)
    }

    private func statusLine(_ id: String) -> Data { Data(#"{"v":1,"id":"\#(id)","cmd":"status"}"#.utf8) + Data([10]) }

    private func wait(until predicate: () -> Bool, seconds: Double = 3) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate() { if Date() > deadline { return false }; usleep(2000) }
        return true
    }

    func testOneRequestInFlightPerConnectionAndGlobalHostCap() throws {
        let fake = FakeAgentHost()
        let gate = DispatchSemaphore(value: 0)
        fake.statusGate = gate
        let server = try server(fake)
        // Always unblock the host queue, even if an assertion below throws.
        defer { fake.lock.lock(); fake.statusGate = nil; fake.lock.unlock(); gate.signal(); server.stop() }

        // Three pipelined requests on one connection: only the first reaches the (blocked) host.
        let pipelined = connected(); defer { close(pipelined) }
        let burst = statusLine("a") + statusLine("b") + statusLine("c")
        _ = burst.withUnsafeBytes { send(pipelined, $0.baseAddress, $0.count, 0) }
        XCTAssertEqual(fake.statusEntered.wait(timeout: .now() + 3), .success)
        usleep(50_000)
        XCTAssertEqual(server.pendingHostTaskCount, 1)
        XCTAssertEqual(fake.hostCalls, 1)

        // Clients that send and hang up keep their slot until the work has run, so the cap holds.
        for index in 0..<(AgentControlServer.maxPendingHostTasks + 4) {
            let fd = connected()
            let line = statusLine("gone-\(index)")
            _ = line.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
            usleep(10_000)
            close(fd)
        }
        XCTAssertTrue(wait { server.pendingHostTaskCount == AgentControlServer.maxPendingHostTasks })
        usleep(50_000)
        XCTAssertEqual(server.pendingHostTaskCount, AgentControlServer.maxPendingHostTasks)
        XCTAssertEqual(errorCode(try request("status")), "busy")
        XCTAssertEqual(errorCode(try request("input", ["buttons": ["A"]])), "busy")
        XCTAssertTrue(fake.inputs.isEmpty)

        // Unblock: the live connection gets all three answers in order; abandoned work never ran.
        fake.lock.lock(); fake.statusGate = nil; fake.lock.unlock()
        gate.signal()
        let answers = readLines(pipelined, count: 3)
        XCTAssertEqual(answers.compactMap { $0["id"] as? String }, ["a", "b", "c"])
        XCTAssertTrue(answers.allSatisfy { $0["ok"] as? Bool == true })
        XCTAssertTrue(wait { server.pendingHostTaskCount == 0 })
        XCTAssertEqual(fake.hostCalls, 3)
        XCTAssertEqual((try request("status"))["ok"] as? Bool, true)
    }

    func testPipelinedFloodBeyondLineLimitIsCut() throws {
        let fake = FakeAgentHost()
        let gate = DispatchSemaphore(value: 0); fake.statusGate = gate
        let server = try server(fake)
        defer { fake.lock.lock(); fake.statusGate = nil; fake.lock.unlock(); gate.signal(); server.stop() }
        let fd = connected(); defer { close(fd) }
        // The first request must reach the host before the flood closes the connection.
        let first = statusLine("first")
        _ = first.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        XCTAssertEqual(fake.statusEntered.wait(timeout: .now() + 3), .success)
        var flood = Data()
        while flood.count <= AgentProtocol.maxLineBytes + 1024 { flood.append(statusLine("x")) }
        _ = flood.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        let lines = readLines(fd, count: 1)
        XCTAssertEqual(lines.first.flatMap { errorCode($0) }, "bad_request")
        XCTAssertEqual(fake.hostCalls, 1)
    }

    private func errorCode(_ response: [String: Any]) -> String? {
        (response["error"] as? [String: Any])?["code"] as? String
    }
    private func request(_ cmd: String, _ args: [String: Any] = [:]) throws -> [String: Any] {
        try AgentClient.request(cmd, args: args, socket: socketPath, timeout: 5)
    }

    func testPermissionsAndRoundTrips() throws {
        let fake = FakeAgentHost(); fake.frame = Self.bgra(width: 1920, height: 1080)
        let server = try server(fake); defer { server.stop() }
        var info = stat()
        XCTAssertEqual(lstat(socketPath, &info), 0); XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertEqual(lstat(URL(fileURLWithPath: socketPath).deletingLastPathComponent().path, &info), 0); XCTAssertEqual(info.st_mode & 0o777, 0o700)
        XCTAssertEqual(lstat(snapshots.path, &info), 0); XCTAssertEqual(info.st_mode & 0o777, 0o700)

        let status = try request("status")
        XCTAssertEqual(status["ok"] as? Bool, true); XCTAssertEqual(status["v"] as? Int, 1)
        XCTAssertNotNil((status["result"] as? [String: Any])?["now"] as? Double)

        let input = try request("input", ["buttons": ["A", "A", "HOME"], "lx": -0.5, "holdMs": 60_000])
        XCTAssertEqual(input["ok"] as? Bool, true)
        XCTAssertEqual(fake.inputs, [AgentInputArgs(buttons: ["A", "HOME"], lx: -0.5, holdMs: 60_000)])

        XCTAssertEqual((try request("release"))["ok"] as? Bool, true)
        XCTAssertEqual(fake.releases, 1)

        let snapshot = try request("snapshot", ["maxWidth": 640])
        let result = try XCTUnwrap(snapshot["result"] as? [String: Any])
        XCTAssertEqual(result["width"] as? Int, 640); XCTAssertEqual(result["height"] as? Int, 360); XCTAssertEqual(result["seq"] as? Int, 7)
        let path = try XCTUnwrap(result["path"] as? String)
        XCTAssertTrue(path.hasPrefix(snapshots.path))
        XCTAssertEqual(lstat(path, &info), 0); XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertNotNil(NSImage(contentsOfFile: path))
        let defaultWidth = try XCTUnwrap((try request("snapshot"))["result"] as? [String: Any])
        XCTAssertEqual(defaultWidth["width"] as? Int, 1280)
    }

    func testErrorCodes() throws {
        let fake = FakeAgentHost()
        let server = try server(fake); defer { server.stop() }
        XCTAssertEqual(errorCode(try request("dance")), "unknown_command")
        XCTAssertEqual(errorCode(try request("input", ["buttons": ["TURBO"]])), "bad_request")
        XCTAssertEqual(errorCode(try request("input", ["buttons": "A"])), "bad_request")
        XCTAssertEqual(errorCode(try request("input", ["lx": 1.5])), "bad_request")
        XCTAssertEqual(errorCode(try request("input", ["ly": true])), "bad_request")
        XCTAssertEqual(errorCode(try request("input", ["holdMs": 0])), "bad_request")
        XCTAssertEqual(errorCode(try request("input", ["holdMs": 60_001])), "bad_request")
        XCTAssertEqual(errorCode(try request("input", ["holdMs": 10.5])), "bad_request")
        XCTAssertEqual(errorCode(try request("snapshot", ["maxWidth": 100])), "bad_request")
        XCTAssertEqual(errorCode(try request("snapshot", ["maxWidth": 4000])), "bad_request")
        XCTAssertEqual(errorCode(try request("snapshot")), "no_frame")
        XCTAssertEqual(errorCode(try raw(Data("not json\n".utf8))), "bad_request")
        XCTAssertEqual(errorCode(try raw(Data(#"{"v":2,"id":"x","cmd":"status"}"#.utf8) + Data([10]))), "bad_request")
        var huge = Data(#"{"v":1,"id":"x","cmd":"status","args":{"pad":""#.utf8)
        huge.append(Data(repeating: 0x61, count: AgentProtocol.maxLineBytes)); huge.append(Data(#""}}"#.utf8)); huge.append(10)
        XCTAssertEqual(errorCode(try raw(huge)), "bad_request")
        fake.lock.lock(); fake.connected = false; fake.lock.unlock()
        XCTAssertEqual(errorCode(try request("input", ["buttons": ["B"]])), "not_connected")
        XCTAssertTrue(fake.inputs.isEmpty)
        let echoed = try raw(Data(#"{"v":1,"id":"abc","cmd":"nope"}"#.utf8) + Data([10]))
        XCTAssertEqual(echoed["id"] as? String, "abc")
    }

    func testSnapshotFilesAreUniquePerRequestAndPruned() throws {
        let fake = FakeAgentHost(); fake.frame = Self.bgra(width: 1920, height: 1080)
        let server = try server(fake); defer { server.stop() }
        let small = try XCTUnwrap((try request("snapshot", ["maxWidth": 640]))["result"] as? [String: Any])
        let large = try XCTUnwrap((try request("snapshot", ["maxWidth": 1280]))["result"] as? [String: Any])
        XCTAssertEqual(small["seq"] as? Int, large["seq"] as? Int)
        let smallPath = try XCTUnwrap(small["path"] as? String), largePath = try XCTUnwrap(large["path"] as? String)
        XCTAssertNotEqual(smallPath, largePath)
        XCTAssertEqual(NSImage(contentsOfFile: smallPath)?.representations.first?.pixelsWide, 640)
        XCTAssertEqual(NSImage(contentsOfFile: largePath)?.representations.first?.pixelsWide, 1280)
        var paths = [smallPath, largePath]
        for _ in 0..<(AgentControlServer.keptSnapshots + 3) {
            paths.append(try XCTUnwrap(((try request("snapshot", ["maxWidth": 320]))["result"] as? [String: Any])?["path"] as? String))
        }
        let kept = try FileManager.default.contentsOfDirectory(atPath: snapshots.path).filter { $0.hasPrefix("snap-") && $0.hasSuffix(".png") }
        XCTAssertEqual(kept.count, AgentControlServer.keptSnapshots)
        XCTAssertEqual(Set(kept), Set(paths.suffix(AgentControlServer.keptSnapshots).map { URL(fileURLWithPath: $0).lastPathComponent }))
    }

    func testConcurrentSnapshotIsBusy() throws {
        let fake = FakeAgentHost(); fake.frame = Self.bgra(width: 320, height: 180)
        let gate = DispatchSemaphore(value: 0); fake.gate = gate
        let server = try server(fake); defer { server.stop() }
        let first = expectation(description: "first snapshot")
        var firstResponse: [String: Any]?
        DispatchQueue.global().async { [socketPath] in
            firstResponse = try? AgentClient.request("snapshot", socket: socketPath, timeout: 5); first.fulfill()
        }
        // The first request is parked on the host queue; a second one must not queue behind it.
        XCTAssertEqual(fake.entered.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(errorCode(try request("snapshot")), "busy")
        gate.signal()
        wait(for: [first], timeout: 5)
        XCTAssertEqual(firstResponse?["ok"] as? Bool, true)
    }

    func testSecondServerRefusedAndStaleSocketReclaimed() throws {
        let fake = FakeAgentHost()
        let first = try server(fake)
        let second = AgentControlServer(socketPath: socketPath, snapshotDirectory: snapshots, host: fake.host, hostQueue: fake.queue)
        XCTAssertThrowsError(try second.start()) { error in
            guard case AgentControlServer.StartError.alreadyRunning = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual((try request("status"))["ok"] as? Bool, true)
        first.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
        XCTAssertThrowsError(try request("status")) { XCTAssertEqual($0 as? AgentClient.Failure, .appNotRunning("switch-remote app is not running (no agent socket)")) }

        // A dead socket file left by a crash is reclaimed.
        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(socketPath.utf8) + [0]) }
        XCTAssertEqual(withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(stale, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }, 0)
        close(stale)
        XCTAssertThrowsError(try request("status")) { XCTAssertEqual($0 as? AgentClient.Failure, .appNotRunning("switch-remote app is not running (no agent socket)")) }
        let third = try server(fake); defer { third.stop() }
        XCTAssertEqual((try request("status"))["ok"] as? Bool, true)
    }

    func testLongPathAndForeignFileAreRefused() throws {
        let long = "/" + String(repeating: "a", count: 110) + "/agent.sock"
        XCTAssertThrowsError(try AgentControlServer(socketPath: long, snapshotDirectory: snapshots, host: FakeAgentHost().host).start()) { error in
            guard case AgentControlServer.StartError.pathTooLong = error else { return XCTFail("\(error)") }
        }
        try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: socketPath).deletingLastPathComponent().path, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: URL(fileURLWithPath: socketPath))
        XCTAssertThrowsError(try AgentControlServer(socketPath: socketPath, snapshotDirectory: snapshots, host: FakeAgentHost().host).start())
        XCTAssertEqual(try String(contentsOfFile: socketPath), "keep")
    }

    func testClientLimit() throws {
        let fake = FakeAgentHost()
        let server = try server(fake); defer { server.stop() }
        var held: [Int32] = []
        defer { held.forEach { close($0) } }
        for _ in 0..<AgentControlServer.maxClients {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(socketPath.utf8) + [0]) }
            XCTAssertEqual(withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }, 0)
            held.append(fd)
        }
        usleep(50_000)
        XCTAssertEqual(errorCode(try request("status")), "busy")
        close(held.removeLast()); usleep(50_000)
        XCTAssertEqual((try request("status"))["ok"] as? Bool, true)
    }

    @MainActor func testLiveControllerHostRefusesInputWithoutLinkAndLeaksNoSecrets() throws {
        let store = PiDeviceStore(directory: root.appendingPathComponent("store"), credentialSave: { _, _ in true })
        let model = ControllerModel(startDiscovery: false, controllerProvider: { [] }, store: store)
        guard case .failure(let error) = model.agentInput(AgentInputArgs(buttons: ["A"])) else { return XCTFail("input accepted without a link") }
        XCTAssertEqual(error.code, .notConnected)
        XCTAssertNil(model.agentStatus()["agent"].flatMap { ($0 as? [String: Any])?["holdUntil"] as? Double })
        XCTAssertEqual(model.agentRelease()["released"] as? Bool, true)
        let text = AgentJSON.string(model.agentStatus()).lowercased()
        for secret in ["host", "token", "key", "pin", "fingerprint", "client", "ssh"] { XCTAssertFalse(text.contains(secret), secret) }
        XCTAssertNil(text.range(of: #"\d+\.\d+\.\d+\.\d+"#, options: .regularExpression))
    }
}
