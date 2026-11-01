import Foundation
import Darwin

/// One request per connection keeps clients simple and ordering obvious.
public enum AgentClient {
    public enum Failure: Error, Equatable {
        /// No socket file, or nobody listening (exit code 3 in switchctl).
        case appNotRunning(String)
        case io(String)
    }

    public static func socketPath(_ explicit: String? = nil) -> String {
        if let explicit, !explicit.isEmpty { return explicit }
        if let env = ProcessInfo.processInfo.environment["SWITCH_REMOTE_SOCKET"], !env.isEmpty { return env }
        return AgentProtocol.defaultSocketPath
    }

    /// Sends one request and returns the decoded response object.
    public static func request(_ cmd: String, args: [String: Any] = [:], socket path: String, timeout: Double = 15) throws -> [String: Any] {
        guard AgentProtocol.socketPathFits(path) else { throw Failure.io("socket path too long") }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.io("socket: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var time = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        if connected != 0 {
            let code = errno
            if code == ENOENT || code == ECONNREFUSED { throw Failure.appNotRunning("switch-remote app is not running (no agent socket)") }
            throw Failure.io("connect: \(String(cString: strerror(code)))")
        }
        let id = UUID().uuidString
        let line = AgentJSON.line(["v": AgentProtocol.version, "id": id, "cmd": cmd, "args": args])
        var offset = 0
        var sendError: String?
        while offset < line.count {
            let sent = line.withUnsafeBytes { Darwin.send(fd, $0.baseAddress! + offset, line.count - offset, 0) }
            // The app may answer and close first (for example "busy"); read that answer below.
            guard sent > 0 else { sendError = "send: \(String(cString: strerror(errno)))"; break }
            offset += sent
        }
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !response.contains(10) {
            let count = Darwin.recv(fd, &buffer, buffer.count, 0)
            if let sendError, count <= 0 { throw Failure.io(sendError) }
            if count == 0 { throw Failure.io("connection closed before a response") }
            guard count > 0 else { throw Failure.io(errno == EAGAIN ? "timed out waiting for the app" : "recv: \(String(cString: strerror(errno)))") }
            response.append(contentsOf: buffer[..<count])
            guard response.count <= AgentProtocol.maxLineBytes else { throw Failure.io("response too large") }
        }
        guard let object = AgentJSON.object(response.prefix(upTo: response.firstIndex(of: 10)!)) else { throw Failure.io("malformed response") }
        return object
    }
}
