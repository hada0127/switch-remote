import XCTest
import Darwin
@testable import GameCapture

final class MoonlightTests: XCTestCase {
    func packet(id: Int = 0, active: Bool = true, buttons: UInt32 = 0, lx: Int = 0) -> MoonlightPacket {
        MoonlightPacket(version: 1, id: id, active: active, buttons: buttons, lt: 255, rt: 0, lx: lx, ly: 0, rx: 0, ry: 0)
    }
    func testSameButtonMappingAsLocalControllerAndAxes() {
        let p = packet(buttons: 0x1000 | 0x200 | 0x40, lx: -32768)
        XCTAssertEqual(p.input(swap: false).buttons, ["A","L_STICK_PRESS","R","ZL"])
        XCTAssertEqual(p.input(swap: true).buttons, ["B","L_STICK_PRESS","R","ZL"])
        XCTAssertEqual(p.input(swap: false).lx, -1)
        XCTAssertFalse(packet(id: 16).valid)
        XCTAssertFalse(packet(lx: 32768).valid)
    }
    func testPhysicalHomeAndStartSelectRemainIndependent() {
        XCTAssertEqual(packet(buttons: 0x400 | 0x1000).input(swap: false).buttons, ["A", "HOME", "ZL"])
        XCTAssertEqual(packet(buttons: 0x30).input(swap: false).buttons, ["MINUS", "PLUS", "ZL"])
    }
    func testNativeBinaryWireLayoutAndAuthentication() {
        let value = ControllerInput(buttons: ["A", "B"], lx: -1, ly: 1)
        let payload = UDPControllerTransport.binaryInputPayload(value)
        XCTAssertEqual(Array(payload), [86,71,70,50,3,0,0,0,0,128,255,127,0,0,0,0])
        let data = UDPControllerTransport.packet(payload: payload, sequence: 42, key: Data(repeating: 107, count: 32))
        XCTAssertEqual(data.count, 56)
        XCTAssertEqual(data.prefix(8), Data([0,0,0,0,0,0,0,42]))
    }
    func testAckWireLayoutMatchesNativeVector() {
        let key = Data(repeating: 107, count: 32)
        let ack = UDPControllerTransport.ack(sequence: 42, key: key)
        // Same 44-byte vector as controller/native/test_protocol.c.
        XCTAssertEqual(ack.map { String(format: "%02x", $0) }.joined(),
                       "000000000000002a56474641e38b9b11208a053cbdee32caae1d44da5f0253a84a1059718a8f7474d32eb380")
        XCTAssertEqual(UDPControllerTransport.ackSequence(ack, key: key), 42)
        var forged = ack; forged[7] = 43
        XCTAssertNil(UDPControllerTransport.ackSequence(forged, key: key))
        XCTAssertNil(UDPControllerTransport.ackSequence(ack, key: Data(repeating: 1, count: 32)))
        XCTAssertNil(UDPControllerTransport.ackSequence(ack.prefix(43), key: key))
        let summary = UDPControllerTransport.rttSummary((1...100).map { Double($0) / 1000 })
        XCTAssertEqual(summary?.p50, 50); XCTAssertEqual(summary?.p99, 99); XCTAssertEqual(summary?.max, 100)
        XCTAssertNil(UDPControllerTransport.rttSummary([]))
    }
    func testAcknowledgedDatagramsProduceRTTAndSilentPeerDoesNot() throws {
        let server = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP); XCTAssertGreaterThanOrEqual(server, 0)
        defer { Darwin.close(server) }
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(server, $0, size) == 0 && Darwin.getsockname(server, $0, &size) == 0 } }
        XCTAssertTrue(bound)
        let key = Data(repeating: 7, count: 32), queue = DispatchQueue(label: "test.udp.ack")
        let transport = try UDPControllerTransport(host: "127.0.0.1", port: Int(UInt16(bigEndian: address.sin_port)), key: key, version: 2, queue: queue)
        // Old Pi: datagram consumed, nothing returned.
        try queue.sync { try transport.send(.neutral) }
        var packet = [UInt8](repeating: 0, count: 64), peer = sockaddr_in(), peerSize = socklen_t(MemoryLayout<sockaddr_in>.size)
        func readable() -> Bool { var p = pollfd(fd: server, events: Int16(POLLIN), revents: 0); return Darwin.poll(&p, 1, 2000) == 1 }
        XCTAssertTrue(readable())
        let received = withUnsafeMutablePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.recvfrom(server, &packet, 64, MSG_DONTWAIT, $0, &peerSize) } }
        XCTAssertEqual(received, 56)
        usleep(20000); queue.sync { transport.readAcks() }
        XCTAssertTrue(queue.sync { transport.rttSamples.isEmpty })
        // New Pi: ack for sequence 2 plus a forged and a duplicate ack.
        try queue.sync { try transport.send(.neutral) }
        XCTAssertTrue(readable())
        XCTAssertEqual(Darwin.recv(server, &packet, 64, MSG_DONTWAIT), 56)
        let ack = UDPControllerTransport.ack(sequence: 2, key: key), forged = UDPControllerTransport.ack(sequence: 2, key: Data(repeating: 8, count: 32))
        for reply in [forged, ack, ack] {
            _ = reply.withUnsafeBytes { bytes in withUnsafePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.sendto(server, bytes.baseAddress, bytes.count, 0, $0, peerSize) } } }
        }
        let deadline = Date().addingTimeInterval(2)
        while queue.sync(execute: { transport.rttSamples.isEmpty }) && Date() < deadline { usleep(1000) }
        usleep(20000)
        let samples = queue.sync { transport.rttSamples }
        XCTAssertEqual(samples.count, 1)
        XCTAssertTrue(samples.allSatisfy { $0 >= 0 && $0 < 2 })
    }
    func testNetworkBurstKeepsButtonEdgesButCoalescesAxes() {
        var q = ControllerTransitionBuffer()
        let a = packet(buttons: 0x1000).input(swap: false)
        let ax = packet(buttons: 0x1000, lx: 32767).input(swap: false)
        let ab = packet(buttons: 0x3000).input(swap: false)
        q.append(a, at: 1); q.append(ax, at: 1.001); q.append(ab, at: 1.002)
        q.append(.neutral, at: 1.003)
        XCTAssertEqual(q.drain(at: 1.01), [ax, ab, .neutral])
        XCTAssertTrue(q.drain(at: 1.02).isEmpty)
        q.append(a, at: 2); q.append(.neutral, at: 2.01)
        XCTAssertEqual(q.drain(at: 2.5), [.neutral])
    }
    func testReleaseStaleAndMultiplePads() {
        var state = MoonlightState()
        state.accept(packet(id: 1, buttons: 0x1000), at: 1)
        state.accept(packet(id: 0, buttons: 0x2000), at: 1)
        XCTAssertTrue(state.current(at: 1.1, swap: false).buttons.contains("B"))
        state.accept(packet(id: 0, active: false), at: 1.2)
        XCTAssertTrue(state.current(at: 1.2, swap: false).buttons.contains("A"))
        XCTAssertEqual(state.current(at: 1.36, swap: false), .neutral)
        state.accept(packet(id: -1), at: 2)
        XCTAssertEqual(state.current(at: 2, swap: false), .neutral)
    }
    func testPrivateSocketDeliveryAndExclusiveOwnership() throws {
        let directory = "/tmp/vgf-test-" + UUID().uuidString
        let path = directory + "/input.sock"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let receiver = MoonlightReceiver()
        let received = expectation(description: "real Unix datagram received")
        receiver.onPacket = { packet in XCTAssertEqual(packet.buttons, 0x1000); received.fulfill() }
        try receiver.start(path: path)
        defer { receiver.stop() }
        let second = MoonlightReceiver()
        XCTAssertThrowsError(try second.start(path: path))
        var info = stat(); XCTAssertEqual(lstat(path, &info), 0); XCTAssertEqual(info.st_mode & 0o777, 0o600)
        let fd = socket(AF_UNIX, SOCK_DGRAM, 0); defer { close(fd) }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let data = try JSONEncoder().encode(packet(buttons: 0x1000))
        let sent = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            } }
        }
        XCTAssertEqual(sent, data.count)
        wait(for: [received], timeout: 2)
        receiver.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        try second.start(path: path); second.stop()
    }
}
