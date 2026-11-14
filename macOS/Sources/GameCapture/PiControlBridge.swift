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
/// Without TLS (`startSerial`), the cable carries both control frames and input.
final class PiControlBridge: ControllerSession, @unchecked Sendable {
    private let queue = DispatchQueue(label: "net.tarucy.controller.network", qos: .userInteractive)
    private let serialLane: SerialLane
    init(serialLane: SerialLane = .shared) { self.serialLane = serialLane }
    private let lock = NSLock()
    private var pending = ControllerTransitionBuffer()
    private var scheduled = false
    private var connection: NWConnection?
    private var udp: UDPControllerTransport?
    private var serialOwned = false
    private var serialOpening = false
    private var serialOpenedAt = 0.0
    private var serialAck = 0.0
    private var serialMetrics: TransportMetrics?
    private var generation: UInt64 = 0
    private var cachedMetrics: TransportMetrics?
    private var serialTimer: DispatchSourceTimer?
    private var lastSerialAttempt = 0.0
    private var serialRetrySeconds = 1.0
    private var latest = ControllerInput.neutral
    private var outboundSequence: UInt64 = 0
    private var buffer = Data()
    private var timer: DispatchSourceTimer?
    private var active = false
    private var lastReply = ProcessInfo.processInfo.systemUptime
    private var startup = true
    private var hidConnected = false
    private var host = ""
    private var device: PairedPi?
    /// Serial link mode: the cable is the control channel (no TLS, no UDP).
    private var serialLink = false
    private var serialReady = false
    private let helloNonce = UInt32.random(in: 1...UInt32.max)
    private var helloStarted = 0.0
    private var lastHelloSent = -Double.infinity
    private var usbCommandID: UInt32 = 0
    private var usbPending: (id: UInt32, action: String, sent: Int, lastSent: Double)?
    var onMessage: (@Sendable (String, String?) -> Void)?
    var onUSBState: (@Sendable (String) -> Void)?

    func controlUSB(_ action: String) {
        queue.async { [self] in
            guard Self.canControlUSB(active: active, hasAuthenticatedTransport: udp != nil || serialReady), action == "detach" || action == "attach" else { return }
            if action == "detach" && !serialLink {
                lock.lock(); pending.append(.neutral, at: ProcessInfo.processInfo.systemUptime); lock.unlock()
                flush()
            }
            guard serialLink else { write(["type": "usb", "action": action]); return }
            usbCommandID = usbCommandID == UInt32.max ? 1 : usbCommandID + 1
            usbPending = (usbCommandID, action, 0, -Double.infinity)
            sendUSBCommand()
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
            guard connection == nil, !serialLink, let port = NWEndpoint.Port(rawValue: UInt16(exactly: endpoint.port) ?? 0), endpoint.port > 0 else { return }
            self.device = device; host = endpoint.host; active = true; publishMetrics()
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
                case .failed(let error): self.linkFail("파이 연결 실패: \(error.localizedDescription)")
                case .waiting(let error): self.onMessage?("waiting", "파이 네트워크 연결을 기다리는 중입니다. \(error.localizedDescription)")
                default: break
                }
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: .seconds(1))
            timer.setEventHandler { [weak self] in
                guard let self, self.active else { return }
                if ProcessInfo.processInfo.systemUptime - self.lastReply > (self.startup ? 70 : 8) { self.linkFail("파이 응답이 없어 다시 연결합니다.") }
            }
            self.timer = timer; timer.resume()
            let probe = DispatchSource.makeTimerSource(queue: queue)
            probe.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20))
            probe.setEventHandler { [weak self] in self?.checkSerial() }
            serialTimer = probe; probe.resume()
            connection.start(queue: queue)
        }
    }
    /// Control over the GPIO UART alone, for when Wi-Fi or Bonjour is down.
    func startSerial(device: PairedPi, path: String) {
        queue.async { [self] in
            guard !active, connection == nil, !serialOwned else { return }
            self.device = device; serialLink = true; serialReady = false; active = true; startup = true
            let now = ProcessInfo.processInfo.systemUptime
            lastReply = now; helloStarted = now
            publishMetrics()
            guard openSerial(path: path, lookup: false) else {
                linkFail("케이블이 사용 중입니다."); return
            }
            let token = generation
            queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.active, self.serialLink, self.serialOpening,
                      self.generation == token else { return }
                self.linkFail("케이블을 열 수 없습니다: 시간 초과")
            }
        }
    }
    @discardableResult private func openSerial(path: String?, lookup: Bool) -> Bool {
        let token = generation
        let accepted = serialLane.open(path: path, lookup: lookup, on: queue,
            result: { [weak self] outcome in
                guard let self, self.generation == token, self.active else { return }
                self.serialOpening = false
                switch outcome {
                case .success(let (openedAt, snapshot)):
                    self.serialOpenedAt = openedAt; self.serialMetrics = snapshot
                    self.publishMetrics()
                    if self.serialLink {
                        self.helloStarted = ProcessInfo.processInfo.systemUptime
                        let timer = DispatchSource.makeTimerSource(queue: self.queue)
                        timer.schedule(deadline: .now() + 1, repeating: .seconds(1))
                        timer.setEventHandler { [weak self] in
                            guard let self, self.active, self.serialReady else { return }
                            if ProcessInfo.processInfo.systemUptime - self.lastReply > (self.startup ? 70 : 8) {
                                self.linkFail("파이 응답이 없어 다시 연결합니다.")
                            }
                        }
                        self.timer = timer; timer.resume()
                        let tick = DispatchSource.makeTimerSource(queue: self.queue)
                        tick.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20))
                        tick.setEventHandler { [weak self] in self?.serialTick() }
                        self.serialTimer = tick; tick.resume()
                        self.sendHello()
                    } else {
                        self.sendSerial(self.latest, sequence: self.nextSequence())
                    }
                case .failure(let error):
                    self.serialOwned = false
                    if self.serialLink { self.linkFail("케이블을 열 수 없습니다: \(error.localizedDescription)") }
                    else { self.serialRetrySeconds = min(self.hidConnected ? 2 : 30, self.serialRetrySeconds * 2) }
                }
            }, failure: { [weak self] in
                guard let self, self.generation == token, self.active else { return }
                self.serialFailure("케이블 연결이 끊겼습니다.")
            }, control: { [weak self] type, body in
                guard let self, self.generation == token, self.active else { return }
                self.receiveControl(type, body)
            }, metrics: { [weak self] snapshot, ack in
                guard let self, self.generation == token, self.active else { return }
                self.serialMetrics = snapshot; self.serialAck = ack; self.publishMetrics()
            })
        if accepted { serialOwned = true; serialOpening = true }
        return accepted
    }
    private func sendHello() {
        guard active, serialOwned else { return }
        lastHelloSent = ProcessInfo.processInfo.systemUptime
        sendControl(type: SerialControl.hello, body: SerialControl.helloBody(nonce: helloNonce))
    }
    /// Resent every 250 ms, at most 4 times, until USB_RESULT, BYE or finish.
    private func sendUSBCommand() {
        guard active, serialReady, serialOwned, var command = usbPending else { return }
        let neutralSequence = command.action == "detach" ? nextSequence() : nil
        guard sendControl(type: SerialControl.usb,
                          body: SerialControl.usbBody(id: command.id, action: command.action),
                          neutralSequence: neutralSequence) else { return }
        command.sent += 1; command.lastSent = ProcessInfo.processInfo.systemUptime
        usbPending = command.sent >= 4 ? nil : command
    }
    @discardableResult private func sendControl(type: UInt8, body: [UInt8], neutralSequence: UInt64? = nil) -> Bool {
        let token = generation
        return serialLane.perform({ serial in
            if let neutralSequence { try serial.send(.neutral, sequence: neutralSequence) }
            try serial.sendControl(type: type, body: body)
        }) { [weak self] error in
            guard let self, let error else { return }
            self.queue.async {
                guard self.generation == token, self.active else { return }
                self.serialFailure("케이블 쓰기 실패: \(error.localizedDescription)")
            }
        }
    }
    private func serialTick() {
        guard active, serialLink else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if !serialReady {
            if now - helloStarted >= 1.5 { linkFail("케이블로 파이 응답이 없습니다."); return }
            if now - lastHelloSent >= 0.25 { sendHello() }
            return
        }
        if let command = usbPending, now - command.lastSent >= 0.25 { sendUSBCommand() }
    }
    private func receiveControl(_ type: UInt8, _ body: [UInt8]) {
        guard active, serialLink else { return }
        switch type {
        case SerialControl.helloReply:
            guard !serialReady, let reply = SerialControl.helloReply(body), reply.nonce == helloNonce else { return }
            lastReply = ProcessInfo.processInfo.systemUptime
            switch reply.result {
            case 0: break
            case 1: fail("다른 컨트롤러 연결이 사용 중입니다."); return
            case 2: fail("파이 등록 정보가 없습니다."); return
            case 3: fail("파이 소프트웨어를 업데이트하세요."); return
            default: fail("파이 연결 오류"); return
            }
            guard reply.version == SerialControl.version else { fail("파이 소프트웨어를 업데이트하세요."); return }
            guard let device, UUID(uuidString: device.id) == reply.id else { fail("케이블에 연결된 파이가 선택한 파이와 다릅니다."); return }
            serialReady = true; startup = true
            flush()
        case SerialControl.status:
            guard serialReady, let status = SerialControl.status(body) else { return }
            lastReply = ProcessInfo.processInfo.systemUptime
            receiveStatus(status.state, backend: status.backend, usbState: status.usbState)
        case SerialControl.usbResult:
            guard serialReady, let result = SerialControl.usbResult(body) else { return }
            lastReply = ProcessInfo.processInfo.systemUptime
            if usbPending?.id == result.id { usbPending = nil }
        case SerialControl.piBye:
            guard let bye = SerialControl.piBye(body), bye.nonce == helloNonce else { return }
            // The Pi already ended the session; do not answer with BYE.
            serialReady = false; usbPending = nil
            switch bye.reason {
            case 2: linkFail("파이가 케이블 입력을 받지 못해 다시 연결합니다.")
            case 3: fail("다른 케이블 연결이 세션을 가져갔습니다.")
            case 4: fail("파이 블루투스를 시작할 수 없습니다.")
            case 5: fail("파이 USB 명령이 실패했습니다.")
            case 6: fail("파이 서비스가 종료되어 다시 연결합니다.")
            default: fail("파이 연결이 종료되어 다시 연결합니다.")
            }
        default: return
        }
    }
    private func write(_ value: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: value) else { return }
        data.append(10)
        connection?.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error { self?.linkFail(error.localizedDescription) }
        })
    }
    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, self.active else { return }
            if let data { self.parse(data) }
            guard self.active else { return }
            if let error { self.linkFail(error.localizedDescription) }
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
                do { udp = try UDPControllerTransport(host: host, port: port, key: key, version: version, queue: queue); publishMetrics(); checkSerial(); flush() }
                catch { fail(error.localizedDescription); return }
            case "status":
                guard let state = message["state"] as? String else { continue }
                receiveStatus(state, backend: message["backend"] as? String, usbState: message["usbState"] as? String)
            case "error": fail(message["message"] as? String ?? "파이 연결 오류"); return
            default: fail("지원하지 않는 파이 응답입니다."); return
            }
        }
    }
    /// Shared by the TLS `status` message and the serial STATUS frame.
    private func receiveStatus(_ state: String, backend: String?, usbState: String?) {
        if let usbState { onUSBState?(usbState) }
        startup = state == "starting" || state == "waiting"
        if state == "connected" && !hidConnected && !serialLink {
            serialRetrySeconds = 1; lastSerialAttempt = 0
            checkSerial()
        }
        hidConnected = state == "connected"
        onMessage?(state, backend)
    }
    static func serialHealthy(openedAt: Double, lastAck: Double, now: Double) -> Bool {
        lastAck > 0 && now - lastAck < 0.1 && lastAck >= openedAt
    }
    private func nextSequence() -> UInt64 {
        outboundSequence += 1
        return outboundSequence
    }
    private func publishMetrics() {
        let snapshot: TransportMetrics?
        if !active { snapshot = nil }
        else if serialLink { snapshot = serialMetrics }
        else if serialOwned && Self.serialHealthy(openedAt: serialOpenedAt, lastAck: serialAck,
                                                   now: ProcessInfo.processInfo.systemUptime) { snapshot = serialMetrics }
        else if let udp { snapshot = udp.metrics }
        else { snapshot = connection == nil ? nil : TransportMetrics(kind: "tls", rtt: nil) }
        lock.lock(); cachedMetrics = snapshot; lock.unlock()
    }
    private func dropSerial() {
        guard serialOwned else { return }
        serialOwned = false; serialOpening = false; serialReady = false
        serialMetrics = nil; serialAck = 0; generation &+= 1
        serialLane.close()
        publishMetrics()
    }
    private func serialFailure(_ message: String) {
        guard serialOwned else { return }
        if serialLink { linkFail(message); return }
        serialRetrySeconds = serialAck == 0 ? min(hidConnected ? 2 : 30, serialRetrySeconds * 2) : 1
        lastSerialAttempt = ProcessInfo.processInfo.systemUptime
        dropSerial()
        if let udp { try? udp.send(latest, sequence: nextSequence()) }
    }
    private func checkSerial() {
        guard active, !serialLink, udp != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if serialOwned {
            if !serialOpening && now - serialOpenedAt > 0.15 &&
                !Self.serialHealthy(openedAt: serialOpenedAt, lastAck: serialAck, now: now) {
                serialFailure("케이블 응답 없음")
            } else if Self.serialHealthy(openedAt: serialOpenedAt, lastAck: serialAck, now: now) {
                serialRetrySeconds = 1
            }
            publishMetrics()
            return
        }
        guard now - lastSerialAttempt >= serialRetrySeconds else { return }
        lastSerialAttempt = now
        _ = openSerial(path: nil, lookup: true)
        publishMetrics()
    }
    /// A busy serial lane drops this input; UDP still receives it when available.
    @discardableResult private func sendSerial(_ value: ControllerInput, sequence: UInt64? = nil) -> Bool {
        guard serialOwned, !serialOpening else { return false }
        let number = sequence ?? nextSequence()
        let token = generation
        if serialLane.perform({ try $0.send(value, sequence: number) }, completion: { [weak self] error in
            guard let self, let error else { return }
            self.queue.async {
                guard self.generation == token, self.active else { return }
                self.serialFailure("케이블 쓰기 실패: \(error.localizedDescription)")
            }
        }) { return true }
        return false
    }
    private func flush() {
        guard active else { return }
        lock.lock(); let values = pending.drain(at: ProcessInfo.processInfo.systemUptime); lock.unlock()
        for value in values {
            guard active else { break }
            latest = value
            if serialLink {
                if serialReady { sendSerial(value) }
                continue
            }
            guard let udp else { continue }
            let shared = nextSequence()
            let healthy = serialOwned && Self.serialHealthy(openedAt: serialOpenedAt, lastAck: serialAck,
                                                              now: ProcessInfo.processInfo.systemUptime)
            let sent = serialOwned && sendSerial(value, sequence: shared)
            if !healthy || !sent { do { try udp.send(value, sequence: shared) } catch { linkFail(error.localizedDescription) } }
        }
        publishMetrics()
    }
    private func fail(_ message: String) {
        guard active else { return }
        onMessage?("error", message); finish()
    }
    /// The link itself failed (network, cable or liveness), so the next attempt may try the other link.
    private func linkFail(_ message: String) {
        guard active else { return }
        onMessage?("link-error", message); finish()
    }
    private func finish(_ completed: (() -> Void)? = nil) {
        guard active else { completed?(); return }
        active = false; hidConnected = false
        let neutralSequence = nextSequence()
        if !serialLink { try? udp?.send(.neutral, sequence: neutralSequence) }
        let sendBye = serialLink && serialReady
        let cableMode = serialLink
        serialReady = false; usbPending = nil
        if serialOwned {
            serialOwned = false; serialOpening = false; generation &+= 1
            serialLane.close(after: { serial in
                if sendBye {
                    try? serial.send(.neutral, sequence: neutralSequence)
                    try? serial.sendControl(type: SerialControl.bye, body: SerialControl.byeBody(nonce: self.helloNonce))
                    serial.drain()
                } else if !cableMode {
                    try? serial.send(.neutral, sequence: neutralSequence)
                }
            }, completion: { completed?() })
        } else { completed?() }
        serialMetrics = nil; serialAck = 0
        udp = nil; serialTimer?.cancel(); serialTimer = nil; timer?.cancel(); timer = nil
        connection?.stateUpdateHandler = nil; connection?.cancel(); connection = nil
        buffer = Data(); publishMetrics()
    }
    func stop() { queue.async { [self] in finish() } }
    /// Best effort for app termination; a stuck serial syscall cannot delay the caller indefinitely.
    func stopNow() {
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in finish { done.signal() } }
        _ = done.wait(timeout: .now() + 0.3)
    }
    func transportMetrics() -> TransportMetrics? {
        lock.lock(); defer { lock.unlock() }
        return cachedMetrics
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
