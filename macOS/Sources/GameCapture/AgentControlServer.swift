import AgentControlProtocol
import CoreVideo
import Darwin
import Foundation
import OSLog

/// What the agent socket may read or do. Closures run on the server's `hostQueue`.
struct AgentControlHost {
    var status: () -> [String: Any]
    var input: (AgentInputArgs) -> Result<[String: Any], AgentError>
    var release: () -> [String: Any]
    var usb: (String) -> Result<[String: Any], AgentError>
    var source: (String) -> Result<[String: Any], AgentError>
    var frame: () -> Result<(buffer: CVPixelBuffer, seq: UInt64, arrivedAt: Double), AgentError>
}

/// Local-only control surface for AI testing: a 0600 Unix socket inside a 0700 directory,
/// peer uid checked on every connection, no network listener.
final class AgentControlServer: @unchecked Sendable {
    enum StartError: LocalizedError {
        case pathTooLong, alreadyRunning, unsafePath(String), system(String)
        var errorDescription: String? {
            switch self {
            case .pathTooLong: "agent socket path is too long"
            case .alreadyRunning: "another instance owns the agent socket"
            case .unsafePath(let detail): "unsafe agent socket path: \(detail)"
            case .system(let detail): detail
            }
        }
    }
    static let maxClients = 4
    /// Host work (status/input/release/snapshot) not yet finished, across all connections.
    /// A slot is returned only when the work has run, never merely because a client left.
    static let maxPendingHostTasks = 8
    static let idleSeconds = 30.0
    static let keptSnapshots = 20

    let socketPath: String
    let snapshotDirectory: URL
    private let host: AgentControlHost
    private let hostQueue: DispatchQueue
    private let queue = DispatchQueue(label: "net.tarucy.agent.server", qos: .userInitiated)
    private let encodeQueue = DispatchQueue(label: "net.tarucy.agent.snapshot", qos: .utility)
    private var acceptSource: DispatchSourceRead?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var encoding = false
    private var pendingHostTasks = 0
    private var bound = false
    private let logger = Logger(subsystem: "net.tarucy.videogamefilter.native", category: "AgentControl")

    /// Server-queue state, except `closed`, which the host queue also reads.
    private final class Client {
        let fd: Int32
        var source: DispatchSourceRead?
        var idle: DispatchSourceTimer?
        var buffer = Data()
        /// One request at a time per connection: later lines wait in `buffer` (bounded by the
        /// line limit) until this response is written. Reading continues so a hang-up is noticed.
        var inFlight = false
        private let lock = NSLock()
        private var isClosed = false
        var closed: Bool {
            get { lock.lock(); defer { lock.unlock() }; return isClosed }
            set { lock.lock(); isClosed = newValue; lock.unlock() }
        }
        init(fd: Int32) { self.fd = fd }
    }

    /// Internal for tests.
    var pendingHostTaskCount: Int { queue.sync { pendingHostTasks } }

    init(socketPath: String = AgentProtocol.defaultSocketPath, snapshotDirectory: URL = AgentProtocol.defaultSnapshotDirectory,
         host: AgentControlHost, hostQueue: DispatchQueue = .main) {
        self.socketPath = socketPath; self.snapshotDirectory = snapshotDirectory
        self.host = host; self.hostQueue = hostQueue
        queue.setSpecific(key: Self.queueKey, value: ())
    }
    deinit { stop() }

    private static func privateDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR else { throw StartError.unsafePath("not a directory owned by this user") }
        if info.st_mode & 0o077 != 0 { guard chmod(path, 0o700) == 0 else { throw StartError.unsafePath("cannot make directory private") } }
    }

    func start() throws {
        try queue.sync {
            guard acceptSource == nil else { return }
            guard AgentProtocol.socketPathFits(socketPath) else { throw StartError.pathTooLong }
            try Self.privateDirectory(URL(fileURLWithPath: socketPath).deletingLastPathComponent().path)
            try Self.privateDirectory(snapshotDirectory.path)
            var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(socketPath.utf8) + [0]) }
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let length = socklen_t(MemoryLayout<sockaddr_un>.size)
            var info = stat()
            if lstat(socketPath, &info) == 0 {
                guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK else { throw StartError.unsafePath("existing file is not this user's socket") }
                let probe = socket(AF_UNIX, SOCK_STREAM, 0)
                guard probe >= 0 else { throw StartError.system("socket failed") }
                let live = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(probe, $0, length) } } == 0
                close(probe)
                if live { throw StartError.alreadyRunning }
                guard unlink(socketPath) == 0 else { throw StartError.system("cannot remove stale agent socket") }
            }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw StartError.system("socket failed") }
            var owned = false
            defer { if !owned { close(fd) } }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC); _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            guard withUnsafePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) } }) == 0 else {
                throw StartError.system("bind failed: \(String(cString: strerror(errno)))")
            }
            guard chmod(socketPath, 0o600) == 0, listen(fd, 8) == 0 else { unlink(socketPath); throw StartError.system("cannot secure agent socket") }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptClients(fd) }
            source.setCancelHandler { close(fd) }
            acceptSource = source; bound = true; owned = true
            source.resume()
        }
    }

    func stop() {
        let work = { [self] in
            acceptSource?.cancel(); acceptSource = nil
            for client in clients.values { closeClient(client) }
            if bound { unlink(socketPath); bound = false }
        }
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil { work() } else { queue.sync(execute: work) }
    }
    private static let queueKey = DispatchSpecificKey<Void>()

    // MARK: connections (all on `queue`)

    private func acceptClients(_ listener: Int32) {
        while true {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            var uid = uid_t(), gid = gid_t()
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { close(fd); continue }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            // Blocking writes with a send timeout; reads use MSG_DONTWAIT.
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let client = Client(fd: fd)
            guard clients.count < Self.maxClients else {
                write(client, AgentJSON.failure(id: nil, AgentError(.busy, "too many agent clients")))
                closeClient(client); continue
            }
            clients[ObjectIdentifier(client)] = client
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self, unowned client] in self?.read(client) }
            source.setCancelHandler { close(fd) }
            client.source = source
            let idle = DispatchSource.makeTimerSource(queue: queue)
            idle.setEventHandler { [weak self, unowned client] in self?.closeClient(client) }
            client.idle = idle
            resetIdle(client)
            idle.resume(); source.resume()
        }
    }

    private func resetIdle(_ client: Client) {
        client.idle?.schedule(deadline: .now() + Self.idleSeconds)
    }

    private func closeClient(_ client: Client) {
        guard !client.closed else { return }
        client.closed = true
        client.idle?.cancel(); client.idle = nil
        if let source = client.source { source.cancel() } else { close(client.fd) }
        client.source = nil
        clients.removeValue(forKey: ObjectIdentifier(client))
    }

    private func read(_ client: Client) {
        guard !client.closed else { return }
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        let count = recv(client.fd, &chunk, chunk.count, MSG_DONTWAIT)
        if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) { closeClient(client); return }
        guard count > 0 else { return }
        resetIdle(client)
        client.buffer.append(contentsOf: chunk[..<count])
        drain(client)
    }

    /// Handles buffered lines until one needs host work; the rest wait for its response.
    private func drain(_ client: Client) {
        while !client.closed, !client.inFlight, let end = client.buffer.firstIndex(of: 10) {
            let line = client.buffer[client.buffer.startIndex..<end]
            client.buffer.removeSubrange(...end)
            guard line.count <= AgentProtocol.maxLineBytes else { tooLong(client); return }
            handle(Data(line), client: client)
        }
        // Unprocessed bytes stay within one line's worth, including requests pipelined behind one in flight.
        if !client.closed, client.buffer.count > AgentProtocol.maxLineBytes { tooLong(client) }
    }

    /// Reserves a host slot for `client`, or answers busy.
    private func begin(_ client: Client, id: Any?) -> Bool {
        guard pendingHostTasks < Self.maxPendingHostTasks else {
            reply(client, id: id, .failure(AgentError(.busy, "too many pending agent requests"))); return false
        }
        pendingHostTasks += 1
        client.inFlight = true
        return true
    }

    /// Runs on `queue` once the host work has finished: frees the slot, answers, handles the next line.
    private func finish(_ client: Client, id: Any?, _ result: Result<[String: Any], AgentError>) {
        pendingHostTasks -= 1
        reply(client, id: id, result)
        client.inFlight = false
        drain(client)
    }

    private func tooLong(_ client: Client) {
        write(client, AgentJSON.failure(id: nil, AgentError(.badRequest, "request line exceeds \(AgentProtocol.maxLineBytes) bytes")))
        closeClient(client)
    }

    private func write(_ client: Client, _ object: [String: Any]) {
        guard !client.closed else { return }
        let data = AgentJSON.line(object)
        var offset = 0
        while offset < data.count {
            let sent = data.withUnsafeBytes { send(client.fd, $0.baseAddress! + offset, data.count - offset, 0) }
            guard sent > 0 else { closeClient(client); return }
            offset += sent
        }
    }

    private func reply(_ client: Client, id: Any?, _ result: Result<[String: Any], AgentError>) {
        switch result {
        case .success(let value): write(client, AgentJSON.success(id: id, result: value))
        case .failure(let error): write(client, AgentJSON.failure(id: id, error))
        }
    }

    /// Runs `body` on the host queue and replies on the server queue. Work for a connection
    /// that has already closed is skipped, so an abandoned request never acts late.
    private func onHost(_ client: Client, id: Any?, _ body: @escaping () -> Result<[String: Any], AgentError>) {
        guard begin(client, id: id) else { return }
        hostQueue.async { [self] in
            let result = Box(client.closed ? .failure(AgentError(.internal, "client disconnected")) : body())
            queue.async { [self] in finish(client, id: id, result.value) }
        }
    }

    private func handle(_ line: Data, client: Client) {
        guard let request = AgentJSON.object(line) else {
            reply(client, id: nil, .failure(AgentError(.badRequest, "request must be one JSON object per line"))); return
        }
        let rawID = request["id"]
        let id: Any? = rawID as? String
        guard rawID == nil || id != nil else { reply(client, id: nil, .failure(AgentError(.badRequest, "id must be a string"))); return }
        guard let v = request["v"].flatMap(AgentJSON.integer), v == AgentProtocol.version else {
            reply(client, id: id, .failure(AgentError(.badRequest, "v must be \(AgentProtocol.version)"))); return
        }
        guard let cmd = request["cmd"] as? String else { reply(client, id: id, .failure(AgentError(.badRequest, "cmd must be a string"))); return }
        let rawArgs = request["args"] ?? [String: Any]()
        guard let args = rawArgs as? [String: Any] else { reply(client, id: id, .failure(AgentError(.badRequest, "args must be an object"))); return }
        let host = host
        switch cmd {
        case "status":
            onHost(client, id: id) {
                var result = host.status(); result["now"] = ProcessInfo.processInfo.systemUptime
                return .success(result)
            }
        case "input":
            let parsed: AgentInputArgs
            do { parsed = try AgentInputArgs.parse(args) }
            catch { reply(client, id: id, .failure(error as? AgentError ?? AgentError(.badRequest, "invalid input"))); return }
            onHost(client, id: id) { host.input(parsed) }
        case "release":
            onHost(client, id: id) { .success(host.release()) }
        case "controller":
            guard args.count == 1, let action = args["action"] as? String, action == "detach" || action == "attach" else {
                reply(client, id: id, .failure(AgentError(.badRequest, "action must be detach or attach"))); return
            }
            onHost(client, id: id) { host.usb(action) }
        case "source":
            guard args.count == 1, let source = args["source"] as? String, ["none", "gamepad", "moonlight"].contains(source) else {
                reply(client, id: id, .failure(AgentError(.badRequest, "source must be none, gamepad or moonlight"))); return
            }
            onHost(client, id: id) { host.source(source) }
        case "snapshot":
            var maxWidth = AgentProtocol.defaultSnapshotWidth
            if let raw = args["maxWidth"] {
                guard let value = AgentJSON.integer(raw), AgentProtocol.snapshotWidthRange.contains(value) else {
                    reply(client, id: id, .failure(AgentError(.badRequest, "maxWidth must be an integer in \(AgentProtocol.snapshotWidthRange.lowerBound)...\(AgentProtocol.snapshotWidthRange.upperBound)"))); return
                }
                maxWidth = value
            }
            snapshot(client, id: id, maxWidth: maxWidth)
        default:
            reply(client, id: id, .failure(AgentError(.unknownCommand, "unknown command; use status, snapshot, input, release, controller or source")))
        }
    }

    private func snapshot(_ client: Client, id: Any?, maxWidth: Int) {
        guard !encoding else { reply(client, id: id, .failure(AgentError(.busy, "a snapshot is already being encoded"))); return }
        guard begin(client, id: id) else { return }
        encoding = true
        let host = host, directory = snapshotDirectory
        hostQueue.async { [self] in
            let frame = Box(client.closed ? .failure(AgentError(.internal, "client disconnected")) : host.frame())
            encodeQueue.async { [self] in
                let result: Result<[String: Any], AgentError>
                switch frame.value {
                case .failure(let error): result = .failure(error)
                case .success(let frame):
                    do {
                        let png = try FrameTap.png(frame.buffer, maxWidth: maxWidth)
                        // Unique per request: a later request for the same frame never replaces a returned file.
                        let url = directory.appendingPathComponent("snap-\(frame.seq)-\(png.width)-\(UUID().uuidString.prefix(8).lowercased()).png")
                        try Self.writePrivate(png.data, to: url)
                        Self.prune(directory)
                        let now = ProcessInfo.processInfo.systemUptime
                        result = .success(["path": url.path, "width": png.width, "height": png.height, "seq": frame.seq,
                                           "arrivedAt": frame.arrivedAt, "ageMs": max(0, (now - frame.arrivedAt) * 1000)])
                    } catch {
                        result = .failure(AgentError(.internal, "snapshot failed: \(error.localizedDescription)"))
                    }
                }
                let boxed = Box(result)
                queue.async { [self] in
                    encoding = false
                    finish(client, id: id, boxed.value)
                }
            }
        }
    }

    private static func writePrivate(_ data: Data, to url: URL) throws {
        let temporary = url.path + ".tmp"
        unlink(temporary)
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StartError.system("cannot create snapshot file") }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        close(fd)
        guard written == data.count, rename(temporary, url.path) == 0 else { unlink(temporary); throw StartError.system("cannot write snapshot file") }
    }

    private static func prune(_ directory: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let snapshots = files.filter { $0.lastPathComponent.hasPrefix("snap-") && $0.pathExtension == "png" }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
        for (url, _) in snapshots.dropFirst(keptSnapshots) { try? fm.removeItem(at: url) }
    }
}

/// Moves non-Sendable values between the server, host and encode queues; each value has one owner at a time.
private struct Box<T>: @unchecked Sendable { let value: T; init(_ value: T) { self.value = value } }

// MARK: live wiring

@MainActor enum AgentControl {
    private static var server: AgentControlServer?
    private static var attempted = false
    private static let logger = Logger(subsystem: "net.tarucy.videogamefilter.native", category: "AgentControl")

    /// Starts once per process. Failure only logs; the app keeps running without the agent socket.
    static func start(capture: CaptureModel, controller: ControllerModel) {
        guard !attempted else { return }
        attempted = true
        let host = AgentControlHost(
            status: { MainActor.assumeIsolated { Box(status(capture: capture, controller: controller)) }.value },
            input: { args in MainActor.assumeIsolated { Box(controller.agentInput(args)) }.value },
            release: { MainActor.assumeIsolated { Box(controller.agentRelease()) }.value },
            usb: { action in MainActor.assumeIsolated { Box(controller.usbAction(action)) }.value },
            source: { value in MainActor.assumeIsolated { Box(controller.selectSource(value)) }.value },
            frame: { MainActor.assumeIsolated { Box(frame(capture: capture)) }.value })
        let server = AgentControlServer(host: host)
        do {
            try server.start()
            self.server = server
            logger.notice("Agent control socket ready")
        } catch {
            logger.error("Agent control socket disabled: \(error.localizedDescription, privacy: .public)")
        }
    }
    static func stop() { server?.stop(); server = nil }

    static func status(capture: CaptureModel, controller: ControllerModel) -> [String: Any] {
        let now = ProcessInfo.processInfo.systemUptime
        var captureStatus: [String: Any] = ["running": capture.running, "hasFrames": capture.hasFrames,
                                            "width": NSNull(), "height": NSNull(), "fps": NSNull(), "lastFrameAgeMs": NSNull()]
        if let info = capture.frameInfo { captureStatus["width"] = info.width; captureStatus["height"] = info.height; captureStatus["fps"] = info.fps }
        if capture.running, let latest = capture.frameTap.latest() { captureStatus["lastFrameAgeMs"] = max(0, (now - latest.arrivedAt) * 1000) }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        var result = controller.agentStatus()
        result["app"] = ["version": version]
        result["capture"] = captureStatus
        return result
    }

    static func frame(capture: CaptureModel) -> Result<(buffer: CVPixelBuffer, seq: UInt64, arrivedAt: Double), AgentError> {
        guard capture.running else { return .failure(AgentError(.captureStopped, "capture is not running")) }
        guard let latest = capture.frameTap.latest(), ProcessInfo.processInfo.systemUptime - latest.arrivedAt <= 2 else {
            return .failure(AgentError(.noFrame, "no capture frame in the last 2 s"))
        }
        return .success(latest)
    }
}
