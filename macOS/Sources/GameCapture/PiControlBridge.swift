import Foundation
import Network
import CryptoKit
import Security

protocol ControllerSession: AnyObject {
    var onMessage: (@Sendable (String, String?) -> Void)? { get set }
    func send(_ value: ControllerInput)
    func stop()
    func transportMetrics() -> TransportMetrics?
}
extension ControllerSession { func transportMetrics() -> TransportMetrics? { nil } }
extension SSHControllerBridge: ControllerSession {}

/// TLS authenticates and owns the session. Gameplay prefers local serial and falls back to UDP.
final class PiControlBridge: ControllerSession, @unchecked Sendable {
    private let queue = DispatchQueue(label: "net.tarucy.controller.network", qos: .userInteractive)
    private let lock = NSLock()
    private var pending = ControllerTransitionBuffer()
    private var scheduled = false
    private var connection: NWConnection?
    private var udp: UDPControllerTransport?
    private var serial: SerialControllerTransport?
    private var serialTimer: DispatchSourceTimer?
    private var lastSerialAttempt = 0.0
    private var serialRetrySeconds = 1.0
    private var latest = ControllerInput.neutral
    private var outboundSequence: UInt64 = 0
    private var serialLast: ControllerInput?
    private var serialLastSent = -Double.infinity
    private var serialDeferred: ControllerInput?
    private var serialAxisWork: DispatchWorkItem?
    private var buffer = Data()
    private var timer: DispatchSourceTimer?
    private var active = false
    private var lastReply = ProcessInfo.processInfo.systemUptime
    private var startup = true
    private var hidConnected = false
    private var host = ""
    private var device: PairedPi?
    var onMessage: (@Sendable (String, String?) -> Void)?
    var onUSBState: (@Sendable (String) -> Void)?

    func controlUSB(_ action: String) {
        queue.async { [self] in
            guard Self.canControlUSB(active: active, hasAuthenticatedTransport: udp != nil), action == "detach" || action == "attach" else { return }
            if action == "detach" {
                lock.lock(); pending.append(.neutral, at: ProcessInfo.processInfo.systemUptime); lock.unlock()
                flush()
            }
            write(["type": "usb", "action": action])
        }
    }
    static func canControlUSB(active: Bool, hasAuthenticatedTransport: Bool) -> Bool {
        active && hasAuthenticatedTransport
    }

    func send(_ value: ControllerInput) {
        lock.lock()
        pending.append(value, at: ProcessInfo.processInfo.systemUptime)
        let enqueue = !scheduled; scheduled = true
        lock.unlock()
        if enqueue {
            queue.async { [self] in
                lock.lock(); scheduled = false; lock.unlock()
                flush()
            }
        }
    }
    func start(device: PairedPi, endpoint: DiscoveredPi, pair: Bool) {
        queue.async { [self] in
            guard connection == nil, let port = NWEndpoint.Port(rawValue: UInt16(exactly: endpoint.port) ?? 0), endpoint.port > 0 else { return }
            self.device = device; host = endpoint.host; active = true
            lastReply = ProcessInfo.processInfo.systemUptime
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
                let reference = sec_trust_copy_ref(trust).takeRetainedValue()
                guard let certificate = SecTrustGetCertificateAtIndex(reference, 0) else { complete(false); return }
                let der = SecCertificateCopyData(certificate) as Data
                let fingerprint = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
                complete(fingerprint == device.fingerprint)
            }, queue)
            let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
            let connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: parameters)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                guard let self, self.active else { return }
                switch state {
                case .ready:
                    var request: [String: Any] = ["type": "authenticate", "client": device.client, "pair": pair]
                    if let token = PiKeychain.read(device.id + ".token") { request["token"] = token }
                    else if let pin = PiKeychain.read(device.id + ".pin") { request["pin"] = pin }
                    else { self.fail("저장된 등록 정보가 없습니다. SD 준비 정보를 다시 가져오세요."); return }
                    self.write(request); self.receive()
                case .failed(let error): self.fail("파이 연결 실패: \(error.localizedDescription)")
                case .waiting(let error): self.onMessage?("waiting", "파이 네트워크 연결을 기다리는 중입니다. \(error.localizedDescription)")
                default: break
                }
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: .seconds(1))
            timer.setEventHandler { [weak self] in
                guard let self, self.active else { return }
                if ProcessInfo.processInfo.systemUptime - self.lastReply > (self.startup ? 70 : 8) { self.fail("파이 응답이 없어 다시 연결합니다.") }
            }
            self.timer = timer; timer.resume()
            let probe = DispatchSource.makeTimerSource(queue: queue)
            probe.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20))
            probe.setEventHandler { [weak self] in self?.checkSerial() }
            serialTimer = probe; probe.resume()
            connection.start(queue: queue)
        }
    }
    private func write(_ value: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: value) else { return }
        data.append(10)
        connection?.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error { self?.fail(error.localizedDescription) }
        })
    }
    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, self.active else { return }
            if let data { self.parse(data) }
            guard self.active else { return }
            if let error { self.fail(error.localizedDescription) }
            else if complete { self.fail("파이 연결이 종료되어 다시 연결합니다.") }
            else { self.receive() }
        }
    }
    private func parse(_ data: Data) {
        buffer.append(data)
        guard buffer.count <= 65536 else { fail("파이 응답 형식 오류"); return }
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: end); buffer.removeSubrange(...end)
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = message["type"] as? String else { fail("파이 응답 형식 오류"); return }
            lastReply = ProcessInfo.processInfo.systemUptime
            switch type {
            case "enrolled":
                guard let device, let token = message["token"] as? String,
                      token.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                      PiKeychain.save(token, account: device.id + ".token") else { fail("파이 연결 키를 키체인에 저장할 수 없습니다."); return }
                write(["type": "confirm"])
                PiKeychain.remove(device.id + ".pin")
                onMessage?("enrolled", nil)
            case "transport":
                guard udp == nil, let version = message["version"] as? Int, (1...2).contains(version),
                      let port = message["port"] as? Int, let encoded = message["key"] as? String,
                      let key = Data(base64Encoded: encoded) else { fail("UDP 연결 정보 오류"); return }
                do { udp = try UDPControllerTransport(host: host, port: port, key: key, version: version, queue: queue); checkSerial(); flush() }
                catch { fail(error.localizedDescription); return }
            case "status":
                guard let state = message["state"] as? String else { continue }
                if let usbState = message["usbState"] as? String { onUSBState?(usbState) }
                startup = state == "starting" || state == "waiting"
                if state == "connected" && !hidConnected {
                    serialRetrySeconds = 1; lastSerialAttempt = 0
                    checkSerial()
                }
                hidConnected = state == "connected"
                onMessage?(state, message["backend"] as? String)
            case "error": fail(message["message"] as? String ?? "파이 연결 오류"); return
            default: fail("지원하지 않는 파이 응답입니다."); return
            }
        }
    }
    static func serialHealthy(openedAt: Double, lastAck: Double, now: Double) -> Bool {
        lastAck > 0 && now - lastAck < 0.1 && lastAck >= openedAt
    }
    private func nextSequence() -> UInt64 {
        outboundSequence += 1
        return outboundSequence
    }
    private func dropSerial() {
        serial = nil
        serialAxisWork?.cancel(); serialAxisWork = nil
        serialDeferred = nil; serialLast = nil
    }
    private func checkSerial() {
        guard active, let udp else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let serial {
            if now - serial.openedAt > 0.15 && !Self.serialHealthy(openedAt: serial.openedAt, lastAck: serial.lastAck, now: now) {
                serialRetrySeconds = serial.lastAck == 0 ? min(hidConnected ? 2 : 30, serialRetrySeconds * 2) : 1
                lastSerialAttempt = now
                dropSerial()
                // Repair any held input immediately after losing the cable.
                try? udp.send(latest, sequence: nextSequence())
            }
            if Self.serialHealthy(openedAt: serial.openedAt, lastAck: serial.lastAck, now: now) { serialRetrySeconds = 1 }
            return
        }
        guard now - lastSerialAttempt >= serialRetrySeconds else { return }
        lastSerialAttempt = now
        guard let path = SerialControllerTransport.devicePath() else { return }
        do {
            serial = try SerialControllerTransport(path: path, queue: queue) { [weak self] in
                guard let self, self.active else { return }
                self.serialRetrySeconds = self.serial?.lastAck == 0 ? min(self.hidConnected ? 2 : 30, self.serialRetrySeconds * 2) : 1
                self.lastSerialAttempt = ProcessInfo.processInfo.systemUptime
                self.dropSerial()
                if let udp = self.udp { try? udp.send(self.latest, sequence: self.nextSequence()) }
            }
            try serial?.send(latest, sequence: nextSequence())
            serialLast = latest; serialLastSent = now
        } catch { serialRetrySeconds = min(hidConnected ? 2 : 30, serialRetrySeconds * 2); lastSerialAttempt = now; dropSerial() }
    }
    /// At 115200, a 29-byte state takes about 2.5 ms. Merge analog-only
    /// bursts into a 4 ms interval; button transitions still go immediately.
    private func sendSerial(_ value: ControllerInput, sequence: UInt64? = nil) throws -> Bool {
        guard let serial else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        if serialLast?.buttons == value.buttons && now - serialLastSent < 0.004 {
            if sequence != nil {
                serialAxisWork?.cancel(); serialAxisWork = nil; serialDeferred = nil
                return false
            }
            serialDeferred = value
            if serialAxisWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.serialAxisWork = nil
                    guard let value = self.serialDeferred, let serial = self.serial else { return }
                    self.serialDeferred = nil
                    do {
                        try serial.send(value, sequence: self.nextSequence())
                        self.serialLast = value; self.serialLastSent = ProcessInfo.processInfo.systemUptime
                    } catch {
                        self.serialRetrySeconds = min(self.hidConnected ? 2 : 30, self.serialRetrySeconds * 2)
                        self.lastSerialAttempt = ProcessInfo.processInfo.systemUptime
                        self.dropSerial()
                        if let udp = self.udp { try? udp.send(self.latest, sequence: self.nextSequence()) }
                    }
                }
                serialAxisWork = work
                queue.asyncAfter(deadline: .now() + (serialLastSent + 0.004 - now), execute: work)
            }
            return false
        }
        serialAxisWork?.cancel(); serialAxisWork = nil; serialDeferred = nil
        try serial.send(value, sequence: sequence ?? nextSequence())
        serialLast = value; serialLastSent = now
        return true
    }
    private func flush() {
        guard active, let udp else { return }
        lock.lock(); let values = pending.drain(at: ProcessInfo.processInfo.systemUptime); lock.unlock()
        for value in values {
            guard active else { break }
            latest = value
            let now = ProcessInfo.processInfo.systemUptime
            let healthy = serial.map { Self.serialHealthy(openedAt: $0.openedAt, lastAck: $0.lastAck, now: now) } ?? false
            let shared = nextSequence()
            if serial != nil {
                do {
                    let sent = try sendSerial(value, sequence: healthy ? nil : shared)
                    if healthy { continue }
                    // When serial sends immediately, both paths share the same
                    // sequence so late UDP cannot replay an older state.
                    _ = sent
                } catch {
                    serialRetrySeconds = min(hidConnected ? 2 : 30, serialRetrySeconds * 2)
                    lastSerialAttempt = ProcessInfo.processInfo.systemUptime
                    dropSerial()
                }
            }
            do { try udp.send(value, sequence: shared) } catch { fail(error.localizedDescription) }
        }
    }
    private func fail(_ message: String) {
        guard active else { return }
        onMessage?("error", message); finish()
    }
    private func finish() {
        active = false; hidConnected = false
        let neutralSequence = nextSequence()
        try? serial?.send(.neutral, sequence: neutralSequence)
        try? udp?.send(ControllerInput.neutral, sequence: neutralSequence)
        udp = nil; dropSerial(); serialTimer?.cancel(); serialTimer = nil; timer?.cancel(); timer = nil
        connection?.stateUpdateHandler = nil; connection?.cancel(); connection = nil
        buffer = Data()
    }
    func stop() { queue.async { [self] in finish() } }
    /// Never call from `queue`.
    func transportMetrics() -> TransportMetrics? {
        queue.sync {
            guard active else { return nil }
            if let serial, Self.serialHealthy(openedAt: serial.openedAt, lastAck: serial.lastAck, now: ProcessInfo.processInfo.systemUptime) { return serial.metrics }
            if let udp { return udp.metrics }
            return connection == nil ? nil : TransportMetrics(kind: "tls", rtt: nil)
        }
    }
}

/// Preserve button edges during a burst; only redundant axis/heartbeat states coalesce.
/// Old backlogs collapse to their latest state instead of replaying delayed actions.
struct ControllerTransitionBuffer {
    private var items: [(ControllerInput, Double)] = []
    mutating func append(_ value: ControllerInput, at now: Double) {
        if let last = items.last, last.0.buttons == value.buttons { items.removeLast() }
        if items.count >= 32 { items.removeAll(keepingCapacity: true) }
        items.append((value, now))
    }
    mutating func drain(at now: Double) -> [ControllerInput] {
        defer { items.removeAll(keepingCapacity: true) }
        guard let last = items.last else { return [] }
        let recent = items.filter { now - $0.1 <= 0.1 }.map(\.0)
        return recent.isEmpty ? [last.0] : recent
    }
}
