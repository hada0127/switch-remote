import XCTest
import Darwin
@testable import GameCapture

private func hex(_ text: String) -> [UInt8] {
    var bytes: [UInt8] = []
    var index = text.startIndex
    while index < text.endIndex {
        let next = text.index(index, offsetBy: 2)
        bytes.append(UInt8(text[index..<next], radix: 16)!)
        index = next
    }
    return bytes
}
private func hexString(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
private let goldenID = "11111111-2222-3333-4444-555555555555"
private var goldenIDBytes: [UInt8] { hex(goldenID.replacingOccurrences(of: "-", with: "")) }

final class SerialControlTests: XCTestCase {
    // Same vectors as controller/native/test_serial.c (PLAN §3.1).
    func testGoldenVectors() {
        XCTAssertEqual(hexString(SerialControl.hello(nonce: 0x01020304)),
                       "a55a1a0101010203040000000000000000000000000000000000000000fd7a")
        XCTAssertEqual(hexString(SerialControl.usb(id: 7, action: "detach")),
                       "a55a1a0200000007010000000000000000000000000000000000000000d233")
        XCTAssertEqual(hexString(SerialControl.bye(nonce: 0x01020304)),
                       "a55a1a03010203040000000000000000000000000000000000000000008278")
        let reply = "a55a1a8101000102030411111111222233334444555555555555000000614d"
        XCTAssertEqual(hexString(SerialFrame.make(control: SerialControl.helloReply, body: [1, 0, 1, 2, 3, 4] + goldenIDBytes)), reply)
        let status = "a55a1a820301636f6e66696775726564000000000000000000000000005751"
        XCTAssertEqual(hexString(SerialFrame.make(control: SerialControl.status, body: [3, 1] + Array("configured".utf8))), status)
        let result = "a55a1a8300000007000000000000000000000000000000000000000000f640"
        XCTAssertEqual(hexString(SerialFrame.make(control: SerialControl.usbResult, body: [0, 0, 0, 7, 0])), result)
        let bye = "a55a1a840102030401000000000000000000000000000000000000000083d2"
        XCTAssertEqual(hexString(SerialFrame.make(control: SerialControl.piBye, body: [1, 2, 3, 4, 1])), bye)

        // Pi → Mac vectors decode to the documented fields.
        let decodedReply = SerialFrame.control(hex(reply)).flatMap { SerialControl.helloReply($0.body) }
        XCTAssertEqual(decodedReply?.version, 1); XCTAssertEqual(decodedReply?.result, 0)
        XCTAssertEqual(decodedReply?.nonce, 0x01020304); XCTAssertEqual(decodedReply?.id, UUID(uuidString: goldenID))
        let decodedStatus = SerialFrame.control(hex(status)).flatMap { SerialControl.status($0.body) }
        XCTAssertEqual(decodedStatus?.state, "connected"); XCTAssertEqual(decodedStatus?.backend, "usb")
        XCTAssertEqual(decodedStatus?.usbState, "configured")
        let decodedResult = SerialFrame.control(hex(result)).flatMap { SerialControl.usbResult($0.body) }
        XCTAssertEqual(decodedResult?.id, 7); XCTAssertEqual(decodedResult?.accepted, true)
        let decodedBye = SerialFrame.control(hex(bye)).flatMap { SerialControl.piBye($0.body) }
        XCTAssertEqual(decodedBye?.nonce, 0x01020304); XCTAssertEqual(decodedBye?.reason, 1)
        XCTAssertEqual(SerialFrame.control(hex(status))?.type, SerialControl.status)
    }

    func testParserClassifiesAckControlAndGarbage() {
        var ack9: [UInt8] = [0xa5, 0x5a, 8, 0, 0, 0, 0, 0, 0, 0, 9]
        var check = SerialFrame.crc(ack9[2...]); ack9 += [UInt8(truncatingIfNeeded: check), UInt8(truncatingIfNeeded: check >> 8)]
        var ack10: [UInt8] = [0xa5, 0x5a, 8, 0, 0, 0, 0, 0, 0, 0, 10]
        check = SerialFrame.crc(ack10[2...]); ack10 += [UInt8(truncatingIfNeeded: check), UInt8(truncatingIfNeeded: check >> 8)]
        let status = hex("a55a1a820301636f6e66696775726564000000000000000000000000005751")
        var corrupt = status; corrupt[6] ^= 0x40
        let input = SerialFrame.make(sequence: 3, input: ControllerInput(buttons: ["B"], lx: 0, ly: 0, rx: 0, ry: 0))
        let stream: [UInt8] = [0x00, 0xa5, 0x13] + input + ack9 + [0xa5, 0x5a, 0x63] + status + corrupt + ack10
        var parser = SerialFrameParser()
        var events: [SerialEvent] = []
        var offset = 0
        while offset < stream.count {
            let end = min(stream.count, offset + 5)
            events += parser.feed(stream[offset..<end]); offset = end
        }
        XCTAssertEqual(events, [.ack(9), .control(SerialControl.status, Array(status[4..<29])), .ack(10)])
        // A full burst at once gives the same result.
        var whole = SerialFrameParser()
        XCTAssertEqual(whole.feed(stream[...]), events)
    }

    func testStatusAndHelloReplyDecoding() {
        let starting = SerialControl.status(SerialControl.body([0, 0]))
        XCTAssertEqual(starting?.state, "starting"); XCTAssertNil(starting?.backend); XCTAssertNil(starting?.usbState)
        let detached = SerialControl.status(SerialControl.body([4, 2] + Array("not attached".utf8)))
        XCTAssertEqual(detached?.state, "detached"); XCTAssertEqual(detached?.backend, "bluetooth")
        XCTAssertEqual(detached?.usbState, "not attached")
        let long = SerialControl.status(SerialControl.body([1, 1] + Array("abcdefghijklmnopqrst".utf8)))
        XCTAssertEqual(long?.state, "connecting"); XCTAssertEqual(long?.usbState, "abcdefghijklmnop")
        XCTAssertEqual(SerialControl.status(SerialControl.body([2, 0]))?.state, "reconnecting")
        XCTAssertNil(SerialControl.status(SerialControl.body([5, 0])))
        XCTAssertNil(SerialControl.status([3, 1]))
        let busy = SerialControl.helloReply(SerialControl.body([1, 1, 0xde, 0xad, 0xbe, 0xef] + goldenIDBytes))
        XCTAssertEqual(busy?.result, 1); XCTAssertEqual(busy?.nonce, 0xdeadbeef); XCTAssertEqual(busy?.id, UUID(uuidString: goldenID))
        XCTAssertEqual(SerialControl.usb(id: 1, action: "attach")[8], 2)
    }

    func testChooseSerialTruthTable() {
        for endpoint in [false, true] { for serial in [false, true] { for prefer in [false, true] { for pair in [false, true] {
            let expected = serial && !pair && (!endpoint || prefer)
            XCTAssertEqual(ControllerModel.chooseSerial(endpointFound: endpoint, serialAvailable: serial, preferSerial: prefer, pair: pair),
                           expected, "endpoint=\(endpoint) serial=\(serial) prefer=\(prefer) pair=\(pair)")
        } } } }
        XCTAssertFalse(ControllerModel.chooseSerial(endpointFound: true, serialAvailable: true, preferSerial: false, pair: false))
        XCTAssertTrue(ControllerModel.chooseSerial(endpointFound: false, serialAvailable: true, preferSerial: false, pair: false))
    }

    @MainActor func testCableAloneAllowsConnectButNotPairing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = UserDefaults.standard.object(forKey: "pi.automatic")
        // No automatic connect: the stub path must never be opened by this test.
        UserDefaults.standard.set(false, forKey: "pi.automatic")
        defer { if let saved { UserDefaults.standard.set(saved, forKey: "pi.automatic") } else { UserDefaults.standard.removeObject(forKey: "pi.automatic") } }
        let store = PiDeviceStore(directory: root, credentialSave: { _, _ in true })
        let enrollment = ["id": goldenID, "name": "pi", "fingerprint": String(repeating: "a", count: 64),
                          "client": UUID().uuidString, "pin": "123456"]
        try store.enroll(JSONSerialization.data(withJSONObject: enrollment))
        let cable = ControllerModel(startDiscovery: false, controllerProvider: { [] }, store: store,
                                    serialProbe: { "/dev/cu.usbserial-TEST" })
        XCTAssertEqual(cable.selectedPi, goldenID)
        XCTAssertTrue(cable.serialCable)
        XCTAssertTrue(cable.canConnect)
        XCTAssertFalse(cable.canPair)
        XCTAssertFalse(cable.running)
        XCTAssertTrue((cable.agentStatus()["controller"] as? [String: Any])?["control"] is NSNull)
        let none = ControllerModel(startDiscovery: false, controllerProvider: { [] }, store: store, serialProbe: { nil })
        XCTAssertFalse(none.serialCable)
        XCTAssertFalse(none.canConnect)
        XCTAssertFalse(none.canPair)
    }

    @MainActor private func cableModel(_ store: PiDeviceStore, path: String, grace: TimeInterval) -> ControllerModel {
        ControllerModel(startDiscovery: false, controllerProvider: { [] }, store: store, serialProbe: { path }, serialGrace: grace)
    }
    @MainActor private func waitMain(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline { if condition() { return true }; try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    // B1: a healthy Wi-Fi start must not pick the cable just because Bonjour has not answered yet.
    @MainActor func testAutoConnectWaitsForBonjourBeforeCable() async throws {
        let pi = try makePty()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = UserDefaults.standard.object(forKey: "pi.automatic")
        UserDefaults.standard.set(true, forKey: "pi.automatic")
        defer { if let saved { UserDefaults.standard.set(saved, forKey: "pi.automatic") } else { UserDefaults.standard.removeObject(forKey: "pi.automatic") } }
        let store = PiDeviceStore(directory: root, credentialSave: { _, _ in true })
        let enrollment = ["id": goldenID, "name": "pi", "fingerprint": String(repeating: "a", count: 64),
                          "client": UUID().uuidString, "pin": "123456"]
        try store.enroll(JSONSerialization.data(withJSONObject: enrollment))

        // Cable present, Bonjour silent: nothing at start, the cable after the grace.
        let late = cableModel(store, path: pi.path, grace: 0.3)
        XCTAssertTrue(late.automatic); XCTAssertTrue(late.canConnect)
        XCTAssertFalse(late.running, "picked the cable before Bonjour had a chance")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(late.running)
        let serialStarted = await waitMain(2) { late.serialSession }
        XCTAssertTrue(serialStarted, "cable not used after the grace")
        XCTAssertNotNil(pi.nextControl(SerialControl.hello, timeout: 1), "no HELLO after the grace")
        late.disconnect()
        UserDefaults.standard.set(true, forKey: "pi.automatic")

        // Bonjour answers during the grace: TLS right away, and the grace end does not switch to the cable.
        let early = cableModel(store, path: pi.path, grace: 0.3)
        XCTAssertFalse(early.running)
        early.discoveryChanged([DiscoveredPi(id: goldenID, name: "pi", host: "127.0.0.1", port: 9)])
        XCTAssertTrue(early.running); XCTAssertFalse(early.serialSession)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(early.serialSession, "grace end switched a TLS start to the cable")
        early.disconnect()
        UserDefaults.standard.set(true, forKey: "pi.automatic")

        // A manual disconnect during the grace cancels the pending cable connect.
        let cancelled = cableModel(store, path: pi.path, grace: 0.3)
        XCTAssertFalse(cancelled.running)
        cancelled.disconnect()
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(cancelled.running, "pending cable connect survived a manual disconnect")
    }

    // MARK: pty bridge (the test plays the Pi on the pty master)

    private func makePty() throws -> PtyPi {
        guard let pty = PtyPi() else { throw XCTSkip("BLOCKED: openpty failed (errno \(errno))") }
        do { _ = try SerialControllerTransport(path: pty.path, queue: DispatchQueue(label: "probe")) {} }
        catch { throw XCTSkip("BLOCKED: pty termios setup failed: \(error)") }
        return pty
    }
    private func device() -> PairedPi {
        PairedPi(id: goldenID, name: "pi", fingerprint: String(repeating: "a", count: 64), client: UUID().uuidString)
    }
    private func wait(_ timeout: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline { if condition() { return true }; usleep(5_000) }
        return condition()
    }

    func testPtySerialSessionHandshakeStatusUSBAndBye() throws {
        let pi = try makePty()
        let recorder = BridgeRecorder()
        let bridge = PiControlBridge()
        bridge.onMessage = { state, message in recorder.message(state, message) }
        bridge.onUSBState = { recorder.usb($0) }
        bridge.startSerial(device: device(), path: pi.path)

        let hello = try XCTUnwrap(pi.nextControl(SerialControl.hello, timeout: 1), "no HELLO")
        XCTAssertEqual(hello[0], 1)
        let nonce = SerialControl.readBigEndian(hello, at: 1)
        XCTAssertNotEqual(nonce, 0)
        pi.write(SerialFrame.make(control: SerialControl.helloReply, body: [1, 0] + SerialControl.bigEndian(nonce) + goldenIDBytes))
        pi.write(SerialFrame.make(control: SerialControl.status, body: [3, 1] + Array("configured".utf8)))
        XCTAssertTrue(wait(2) { recorder.contains("connected", "usb") && recorder.usbStates.contains("configured") },
                      "messages: \(recorder.messages)")

        // Input goes over the cable, and its ACK feeds serial RTT metrics.
        bridge.send(ControllerInput(buttons: ["A"], lx: 0, ly: 0, rx: 0, ry: 0))
        let input = try XCTUnwrap(pi.nextFrame(timeout: 1) { $0[2] == 24 && $0[15...18] != [0, 0, 0, 0] }, "no input frame")
        var ack: [UInt8] = [0xa5, 0x5a, 8] + Array(input[3..<11])
        let check = SerialFrame.crc(ack[2...]); ack += [UInt8(truncatingIfNeeded: check), UInt8(truncatingIfNeeded: check >> 8)]
        pi.write(ack)
        XCTAssertTrue(wait(1) { (bridge.transportMetrics()?.rtt?.samples ?? 0) > 0 })
        XCTAssertEqual(bridge.transportMetrics()?.kind, "serial")

        // Detach is resent every 250 ms until USB_RESULT arrives.
        bridge.controlUSB("detach")
        let first = try XCTUnwrap(pi.nextControl(SerialControl.usb, timeout: 1), "no USB command")
        XCTAssertEqual(SerialControl.readBigEndian(first, at: 0), 1); XCTAssertEqual(first[4], 1)
        let second = try XCTUnwrap(pi.nextControl(SerialControl.usb, timeout: 1), "USB command not resent")
        XCTAssertEqual(Array(second[0..<5]), Array(first[0..<5]))
        pi.write(SerialFrame.make(control: SerialControl.usbResult, body: [0, 0, 0, 1, 0]))
        XCTAssertNil(pi.nextControl(SerialControl.usb, timeout: 0.7), "USB command resent after USB_RESULT")

        bridge.stop()
        let bye = try XCTUnwrap(pi.nextControl(SerialControl.bye, timeout: 1), "no BYE on stop")
        XCTAssertEqual(SerialControl.readBigEndian(bye, at: 0), nonce)
        XCTAssertFalse(recorder.contains("link-error", nil) || recorder.contains("error", nil))
    }

    // App termination: BYE must already be on the wire when stopNow returns.
    func testPtySerialStopNowWritesByeBeforeReturn() throws {
        let pi = try makePty()
        let recorder = BridgeRecorder()
        let bridge = PiControlBridge()
        bridge.onMessage = { state, message in recorder.message(state, message) }
        bridge.startSerial(device: device(), path: pi.path)
        let hello = try XCTUnwrap(pi.nextControl(SerialControl.hello, timeout: 1), "no HELLO")
        let nonce = SerialControl.readBigEndian(hello, at: 1)
        pi.write(SerialFrame.make(control: SerialControl.helloReply, body: [1, 0] + SerialControl.bigEndian(nonce) + goldenIDBytes))
        pi.write(SerialFrame.make(control: SerialControl.status, body: [3, 1] + Array("configured".utf8)))
        XCTAssertTrue(wait(2) { recorder.contains("connected", nil) },
                      "messages: \(recorder.messages)")

        bridge.stopNow()
        let bye = try XCTUnwrap(pi.nextControl(SerialControl.bye, timeout: 0), "BYE not written before stopNow returned")
        XCTAssertEqual(SerialControl.readBigEndian(bye, at: 0), nonce)
    }

    // Pi BYE reason 2 (cable input lost) retries on the other link; reason 1 (session end) does not.
    func testPtySerialPiByeReasons() throws {
        for (reason, expected) in [(UInt8(2), "link-error"), (UInt8(1), "error")] {
            let pi = try makePty()
            let recorder = BridgeRecorder()
            let bridge = PiControlBridge()
            bridge.onMessage = { state, message in recorder.message(state, message) }
            bridge.startSerial(device: device(), path: pi.path)
            let hello = try XCTUnwrap(pi.nextControl(SerialControl.hello, timeout: 1), "no HELLO")
            let nonce = SerialControl.readBigEndian(hello, at: 1)
            pi.write(SerialFrame.make(control: SerialControl.helloReply, body: [1, 0] + SerialControl.bigEndian(nonce) + goldenIDBytes))
            pi.write(SerialFrame.make(control: SerialControl.status, body: [3, 1] + Array("configured".utf8)))
            XCTAssertTrue(wait(2) { recorder.contains("connected", "usb") }, "messages: \(recorder.messages)")
            // A BYE for another session is ignored.
            pi.write(SerialFrame.make(control: SerialControl.piBye, body: SerialControl.bigEndian(nonce &+ 1) + [reason]))
            pi.write(SerialFrame.make(control: SerialControl.piBye, body: SerialControl.bigEndian(nonce) + [reason]))
            XCTAssertTrue(wait(1) { recorder.contains(expected, nil) }, "reason \(reason): \(recorder.messages)")
            XCTAssertFalse(recorder.contains(expected == "error" ? "link-error" : "error", nil), "reason \(reason): \(recorder.messages)")
            XCTAssertNil(pi.nextControl(SerialControl.bye, timeout: 0.3), "Mac answered a Pi BYE")
            bridge.stop()
        }
    }

    func testPtySerialHelloTimeoutIsLinkError() throws {
        let pi = try makePty()
        let recorder = BridgeRecorder()
        let bridge = PiControlBridge()
        bridge.onMessage = { state, message in recorder.message(state, message) }
        let started = Date()
        bridge.startSerial(device: device(), path: pi.path)
        XCTAssertTrue(wait(3) { recorder.contains("link-error", nil) }, "messages: \(recorder.messages)")
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(elapsed, 1.4); XCTAssertLessThan(elapsed, 2.5)
        var hellos = 0
        while pi.nextControl(SerialControl.hello, timeout: 0.05) != nil { hellos += 1 }
        XCTAssertGreaterThanOrEqual(hellos, 4)
        XCTAssertNil(pi.nextControl(SerialControl.bye, timeout: 0.1), "BYE sent before READY")
    }

    func testPtySerialBusyAndWrongPiAreErrors() throws {
        for (result, id, expected) in [(UInt8(1), goldenIDBytes, "다른 컨트롤러 연결이 사용 중입니다."),
                                       (UInt8(0), [UInt8](repeating: 0x99, count: 16), "케이블에 연결된 파이가 선택한 파이와 다릅니다.")] {
            let pi = try makePty()
            let recorder = BridgeRecorder()
            let bridge = PiControlBridge()
            bridge.onMessage = { state, message in recorder.message(state, message) }
            bridge.startSerial(device: device(), path: pi.path)
            let hello = try XCTUnwrap(pi.nextControl(SerialControl.hello, timeout: 1))
            let nonce = SerialControl.readBigEndian(hello, at: 1)
            // A reply for another bridge instance is ignored.
            pi.write(SerialFrame.make(control: SerialControl.helloReply, body: [1, result] + SerialControl.bigEndian(nonce &+ 1) + id))
            pi.write(SerialFrame.make(control: SerialControl.helloReply, body: [1, result] + SerialControl.bigEndian(nonce) + id))
            XCTAssertTrue(wait(1) { recorder.contains("error", expected) }, "messages: \(recorder.messages)")
            XCTAssertFalse(recorder.contains("link-error", nil))
        }
    }
}

final class BridgeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedMessages: [(String, String?)] = []
    private var storedUSB: [String] = []
    func message(_ state: String, _ detail: String?) { lock.lock(); storedMessages.append((state, detail)); lock.unlock() }
    func usb(_ value: String) { lock.lock(); storedUSB.append(value); lock.unlock() }
    var messages: [(String, String?)] { lock.lock(); defer { lock.unlock() }; return storedMessages }
    var usbStates: [String] { lock.lock(); defer { lock.unlock() }; return storedUSB }
    /// A nil detail matches any detail.
    func contains(_ state: String, _ detail: String?) -> Bool {
        messages.contains { $0.0 == state && (detail == nil || $0.1 == detail) }
    }
}

/// The Pi side of a pseudo terminal: reads Mac → Pi frames (input LEN 24, control LEN 26).
final class PtyPi {
    let master: Int32
    let slave: Int32
    let path: String
    private var received: [UInt8] = []
    private var frames: [[UInt8]] = []
    init?() {
        var master: Int32 = -1, slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0, let name = ttyname(slave) else { return nil }
        self.master = master; self.slave = slave; path = String(cString: name)
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
    }
    deinit { close(master); close(slave) }
    func write(_ bytes: [UInt8]) {
        let count = bytes.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
        precondition(count == bytes.count)
    }
    private func pump() {
        var chunk = [UInt8](repeating: 0, count: 512)
        while true {
            let n = Darwin.read(master, &chunk, chunk.count)
            guard n > 0 else { break }
            received += chunk[..<n]
        }
        while received.count >= 3 {
            if received[0] != 0xa5 || received[1] != 0x5a { received.removeFirst(); continue }
            let size = received[2] == 24 ? 29 : (received[2] == 26 ? 31 : 0)
            guard size > 0 else { received.removeFirst(); continue }
            guard received.count >= size else { break }
            let frame = Array(received.prefix(size))
            let check = SerialFrame.crc(frame[2..<(size - 2)])
            if frame[size - 2] == UInt8(truncatingIfNeeded: check) && frame[size - 1] == UInt8(truncatingIfNeeded: check >> 8) {
                frames.append(frame); received.removeFirst(size)
            } else { received.removeFirst() }
        }
    }
    /// Next frame matching `match`; frames before it are discarded.
    func nextFrame(timeout: Double, _ match: ([UInt8]) -> Bool) -> [UInt8]? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            pump()
            while !frames.isEmpty {
                let frame = frames.removeFirst()
                if match(frame) { return frame }
            }
            usleep(2_000)
        } while Date() < deadline
        return nil
    }
    /// Body of the next control frame of `type`.
    func nextControl(_ type: UInt8, timeout: Double) -> [UInt8]? {
        nextFrame(timeout: timeout) { $0[2] == 26 && $0[3] == type }.map { Array($0[4..<29]) }
    }
}
