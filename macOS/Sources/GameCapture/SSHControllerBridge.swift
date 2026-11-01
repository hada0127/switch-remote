import Foundation
import Darwin

/// SSH owns the session lifecycle; input travels over authenticated, nonblocking UDP.
final class SSHControllerBridge: @unchecked Sendable {
    private let queue = DispatchQueue(label: "net.tarucy.controller.ssh")
    private let lock = NSLock()
    private let readerLock = NSLock()
    private var readersClosed = false
    private var latest: Data?
    private var writeScheduled = false
    private var active = false
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var errors: Pipe?
    private var timer: DispatchSourceTimer?
    private var udp: UDPControllerTransport?
    private var host = ""
    private var received = Data()
    private var stderr = Data()
    private var started = Date()
    private var lastReply = Date()
    private var sawReply = false
    private var reportedError = false
    var onMessage: (@Sendable (String, String?) -> Void)?

    func send(_ value: ControllerInput) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        lock.lock()
        latest = data
        let schedule = !writeScheduled
        writeScheduled = true
        lock.unlock()
        if schedule {
            queue.async { [self] in
                lock.lock(); writeScheduled = false; lock.unlock()
                tick()
            }
        }
    }
    func start(_ config: PiConnection, pair: Bool) {
        guard config.valid else { onMessage?("error", "파이 주소, 사용자 이름과 SSH 키를 확인하세요."); return }
        queue.async { [self] in
            guard process == nil else { return }
            host = config.host
            let task = Process(), stdin = Pipe(), stdout = Pipe(), err = Pipe()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            task.arguments = config.arguments(pair: pair)
            task.standardInput = stdin; task.standardOutput = stdout; task.standardError = err
            input = stdin; output = stdout; errors = err; process = task
            for handle in [stdout.fileHandleForReading, err.fileHandleForReading] {
                let fd = handle.fileDescriptor
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            }
            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                guard let self else { return }
                self.readerLock.lock(); defer { self.readerLock.unlock() }
                guard !self.readersClosed else { return }
                let data = self.readAvailable(handle)
                self.queue.async { self.read(data) }
            }
            err.fileHandleForReading.readabilityHandler = { [weak self] handle in
                guard let self else { return }
                self.readerLock.lock(); defer { self.readerLock.unlock() }
                guard !self.readersClosed else { return }
                let data = self.readAvailable(handle)
                self.queue.async { self.stderr.append(data.prefix(max(0, 4096 - self.stderr.count))) }
            }
            task.terminationHandler = { [self] task in
                readerLock.lock()
                let canDrain = !readersClosed
                readersClosed = true
                stdout.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                let finalOutput = canDrain ? ((try? stdout.fileHandleForReading.readToEnd()) ?? Data()) : Data()
                let finalError = canDrain ? ((try? err.fileHandleForReading.readToEnd()) ?? Data()) : Data()
                queue.async { [self] in
                    let intentional = !active
                    read(finalOutput)
                    stderr.append(finalError.prefix(max(0, 4096 - stderr.count)))
                    let detail = String(data: stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    cleanup()
                    if !intentional && !reportedError {
                        onMessage?("error", detail?.isEmpty == false ? detail : "파이 연결이 종료됐습니다 (\(task.terminationStatus)).")
                    }
                }
                readerLock.unlock()
            }
            do {
                try task.run()
                let fd = stdin.fileHandleForWriting.fileDescriptor
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                // A closed SSH pipe must report EPIPE instead of terminating the app.
                _ = fcntl(fd, F_SETNOSIGPIPE, 1)
                active = true; started = Date(); lastReply = started
                let ticker = DispatchSource.makeTimerSource(queue: queue)
                ticker.schedule(deadline: .now(), repeating: .milliseconds(16))
                ticker.setEventHandler { [weak self] in self?.tick() }
                timer = ticker; ticker.resume()
            } catch { cleanup(); onMessage?("error", error.localizedDescription) }
        }
    }
    func transportMetrics() -> TransportMetrics? {
        queue.sync { active ? TransportMetrics(kind: "ssh", rtt: nil) : nil }
    }
    func stop() {
        lock.lock(); latest = nil; lock.unlock()
        queue.async { [self] in
            if let neutral = try? JSONEncoder().encode(ControllerInput.neutral) { try? udp?.send(neutral) }
            udp = nil
            active = false
            try? input?.fileHandleForWriting.close() // EOF: Pi releases inputs and exits.
            timer?.cancel(); timer = nil
            guard let task = process else { cleanup(); return }
            guard task.isRunning else { return } // terminationHandler owns final drain and cleanup
            queue.asyncAfter(deadline: .now() + 10) { if task.isRunning { task.terminate() } }
            queue.asyncAfter(deadline: .now() + 15) { if task.isRunning { kill(task.processIdentifier, SIGKILL) } }
        }
    }
    private func readAvailable(_ handle: FileHandle) -> Data {
        var bytes = [UInt8](repeating: 0, count: 65536)
        let count = bytes.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count) }
        return count > 0 ? Data(bytes.prefix(count)) : Data()
    }
    private func tick() {
        guard active else { return }
        if Date().timeIntervalSince(sawReply ? lastReply : started) > (sawReply ? 5 : 60) {
            onMessage?("error", "파이 응답이 없습니다. 전원과 Wi-Fi를 확인하세요.")
            stop(); return
        }
        guard let udp else { return }
        lock.lock(); let payload = latest; latest = nil; lock.unlock()
        guard let payload else { return }
        do { try udp.send(payload) }
        catch { onMessage?("error", "UDP 입력 전송 실패: \(error.localizedDescription)"); stop() }
    }

    private func read(_ data: Data) {
        guard active, !data.isEmpty else { return }
        received.append(data)
        guard received.count <= 65536 else { onMessage?("error", "파이 응답 형식 오류"); stop(); return }
        while let end = received.firstIndex(of: 10) {
            let line = received.prefix(upTo: end)
            received.removeSubrange(...end)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            if type == "transport" {
                guard udp == nil, object["version"] as? Int == 1,
                      let port = object["port"] as? Int, let encodedKey = object["key"] as? String,
                      let key = Data(base64Encoded: encodedKey) else {
                    onMessage?("error", "파이 UDP 연결 정보 오류"); stop(); return
                }
                do { udp = try UDPControllerTransport(host: host, port: port, key: key); tick() }
                catch { onMessage?("error", error.localizedDescription); stop(); return }
            } else if type == "status", let state = object["state"] as? String {
                lastReply = Date(); if state == "starting" { sawReply = false; started = Date() } else { sawReply = true }; onMessage?(state, nil)
            } else if type == "error" {
                reportedError = true
                onMessage?("error", object["message"] as? String ?? "파이 오류"); stop(); return
            }
        }
    }
    private func cleanup() {
        active = false; timer?.cancel(); timer = nil
        readerLock.lock(); defer { readerLock.unlock() }
        readersClosed = true
        output?.fileHandleForReading.readabilityHandler = nil
        errors?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        try? output?.fileHandleForReading.close(); try? errors?.fileHandleForReading.close()
        input = nil; output = nil; errors = nil; process?.terminationHandler = nil; process = nil; udp = nil; received = Data()
    }
}
