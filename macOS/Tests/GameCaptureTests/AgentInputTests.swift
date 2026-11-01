import XCTest
import Darwin
import GameController
import AgentControlProtocol
@testable import GameCapture

final class AgentInputTests: XCTestCase {
    private func pipeline(active: Bool) -> (ControllerInputPipeline, UUID, RecordingControllerSession) {
        let pipeline = ControllerInputPipeline(heartbeat: false)
        let generation = pipeline.select(GCController.withExtendedGamepad(), remote: false)
        pipeline.setApplicationActive(active)
        let session = RecordingControllerSession(); pipeline.setSession(session)
        usleep(3000)
        _ = session.drain()
        return (pipeline, generation, session)
    }

    private func waitForNeutral(_ session: RecordingControllerSession, seconds: Double = 2) {
        let deadline = Date().addingTimeInterval(seconds)
        while session.timeline().last?.0 != .neutral && Date() < deadline { usleep(1000) }
    }

    func testHoldIgnoresFocusGateAndReleasesExactlyOnce() {
        let (pipeline, _, session) = pipeline(active: false)
        let start = ProcessInfo.processInfo.systemUptime
        let result = pipeline.setAgent(ControllerInput(buttons: ["HOME"]), holdMs: 80)
        XCTAssertNotNil(result.forwardedAt)
        XCTAssertEqual(result.until, start + 0.08, accuracy: 0.02)
        XCTAssertEqual(pipeline.agentHoldUntil, result.until)
        waitForNeutral(session)
        usleep(50_000)
        let sent = session.timeline()
        XCTAssertEqual(sent.map(\.0), [ControllerInput(buttons: ["HOME"]), .neutral])
        XCTAssertGreaterThanOrEqual(sent[1].1, result.until - 0.002)
        XCTAssertNil(pipeline.agentHoldUntil)
        pipeline.setSession(nil)
    }

    func testSessionChangeAndSelectionResetDropHold() {
        let (pipeline, _, session) = pipeline(active: true)
        pipeline.setAgent(ControllerInput(buttons: ["DPAD_DOWN"]), holdMs: 2000)
        pipeline.setSession(nil)
        XCTAssertNil(pipeline.agentHoldUntil)
        XCTAssertEqual(session.drain(), [ControllerInput(buttons: ["DPAD_DOWN"]), .neutral])

        let second = RecordingControllerSession(); pipeline.setSession(second); _ = second.drain()
        pipeline.setAgent(ControllerInput(buttons: ["DPAD_DOWN"]), holdMs: 2000)
        pipeline.select(GCController.withExtendedGamepad(), remote: false, reset: true)
        XCTAssertNil(pipeline.agentHoldUntil)
        XCTAssertEqual(second.drain().last, .neutral)
        usleep(20_000)
        pipeline.queue.sync { pipeline.tick() }
        XCTAssertTrue(second.drain().isEmpty)
        pipeline.setSession(nil)
    }

    func testClearAgentSendsNeutralEdge() {
        let (pipeline, _, session) = pipeline(active: false)
        pipeline.setAgent(ControllerInput(lx: 1), holdMs: 2000)
        pipeline.clearAgent()
        XCTAssertNil(pipeline.agentHoldUntil)
        // An axis-only release inside the 2 ms window goes out at the window boundary.
        waitForNeutral(session)
        XCTAssertEqual(session.drain(), [ControllerInput(lx: 1), .neutral])
        pipeline.clearAgent()
        XCTAssertTrue(session.drain().isEmpty)
        pipeline.setSession(nil)
    }

    func testMergesWithGamepadButtonsAndOverridesNonZeroAxes() {
        let (pipeline, generation, session) = pipeline(active: true)
        pipeline.queue.sync { pipeline.updateLocal(ControllerInput(buttons: ["L"], lx: 0.5, ly: 0.25), generation: generation) }
        _ = session.drain()
        let before = pipeline.metrics
        pipeline.setAgent(ControllerInput(buttons: ["A", "L"], lx: -1), holdMs: 2000)
        XCTAssertEqual(session.drain(), [ControllerInput(buttons: ["A", "L"], lx: -1, ly: 0.25)])
        pipeline.clearAgent()
        XCTAssertEqual(session.drain(), [ControllerInput(buttons: ["L"], lx: 0.5, ly: 0.25)])
        // Agent edges are not gamepad callbacks.
        XCTAssertEqual(pipeline.metrics.forwardedChanges, before.forwardedChanges)
        XCTAssertEqual(pipeline.metrics.maxForwardDelayMS, before.maxForwardDelayMS)
        pipeline.setSession(nil)
    }

    func testNewHoldReplacesPreviousOne() {
        let (pipeline, _, session) = pipeline(active: false)
        pipeline.setAgent(ControllerInput(buttons: ["DPAD_UP"]), holdMs: 40)
        let second = pipeline.setAgent(ControllerInput(buttons: ["DPAD_LEFT"]), holdMs: 150)
        usleep(80_000)
        XCTAssertEqual(session.timeline().last?.0, ControllerInput(buttons: ["DPAD_LEFT"]))
        XCTAssertEqual(pipeline.agentHoldUntil, second.until)
        waitForNeutral(session)
        XCTAssertEqual(session.drain(), [ControllerInput(buttons: ["DPAD_UP"]), ControllerInput(buttons: ["DPAD_LEFT"]), .neutral])
        pipeline.setSession(nil)
    }

    func testOverlappingHoldsChainWithoutNeutralEdge() {
        let (pipeline, _, session) = pipeline(active: false)
        // Chained movement: every hold is replaced long before it could expire.
        for _ in 0..<5 {
            pipeline.setAgent(ControllerInput(lx: 1), holdMs: 60_000)
            usleep(5_000)
        }
        pipeline.setAgent(ControllerInput(buttons: ["B"], lx: 1), holdMs: 60_000)
        usleep(20_000)
        XCTAssertEqual(session.drain(), [ControllerInput(lx: 1), ControllerInput(buttons: ["B"], lx: 1)])
        XCTAssertNotNil(pipeline.agentHoldUntil)
        pipeline.clearAgent()
        XCTAssertEqual(session.drain(), [.neutral])
        XCTAssertNil(pipeline.agentHoldUntil)
        pipeline.setSession(nil)
    }

    func testHeartbeatRepeatsHoldUntilExpiryThenOnlyNeutral() {
        let pipeline = ControllerInputPipeline() // real 20 ms heartbeat
        pipeline.select(nil, remote: false)
        let session = RecordingControllerSession(); pipeline.setSession(session)
        usleep(30_000); _ = session.drain()
        let result = pipeline.setAgent(ControllerInput(buttons: ["DPAD_DOWN"]), holdMs: 200)
        let deadline = Date().addingTimeInterval(2)
        while pipeline.agentHoldUntil != nil && Date() < deadline { usleep(2000) }
        usleep(100_000)
        let sent = session.timeline()
        let held = sent.filter { $0.0 == ControllerInput(buttons: ["DPAD_DOWN"]) }
        XCTAssertGreaterThanOrEqual(held.count, 3) // the edge plus heartbeats during the hold
        XCTAssertTrue(held.allSatisfy { $0.1 < result.until + 0.002 })
        let firstNeutral = sent.firstIndex { $0.0 == .neutral && $0.1 >= result.until - 0.002 }
        XCTAssertNotNil(firstNeutral)
        if let firstNeutral { XCTAssertTrue(sent[firstNeutral...].allSatisfy { $0.0 == .neutral }) }
        pipeline.setSession(nil)
    }

    @MainActor func testLinkLossDropsHoldAndReconnectDoesNotRestoreIt() {
        let store = PiDeviceStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), credentialSave: { _, _ in true })
        let model = ControllerModel(startDiscovery: false, controllerProvider: { [] }, store: store)
        let session = RecordingControllerSession()
        model.inputPipeline.setSession(session)
        model.setLinkConnected(true, backend: "usb")
        usleep(5_000); _ = session.drain()
        guard case .success = model.agentInput(AgentInputArgs(buttons: ["DPAD_DOWN"], holdMs: 60_000)) else { return XCTFail("input refused") }
        XCTAssertNotNil(model.inputPipeline.agentHoldUntil)
        model.setLinkConnected(false, backend: nil) // e.g. "reconnecting" on the same session
        XCTAssertNil(model.inputPipeline.agentHoldUntil)
        XCTAssertEqual(session.timeline().last?.0, .neutral)
        model.setLinkConnected(true, backend: "usb")
        usleep(100_000) // several heartbeats
        let afterRelease = session.timeline().drop { $0.0 != .neutral }
        XCTAssertFalse(afterRelease.contains { $0.0.buttons.contains("DPAD_DOWN") })
        XCTAssertNil(model.inputPipeline.agentHoldUntil)
        model.inputPipeline.setSession(nil)
    }

    func testNoSessionReportsNilForwardedAt() {
        let pipeline = ControllerInputPipeline(heartbeat: false)
        XCTAssertNil(pipeline.setAgent(ControllerInput(buttons: ["B"]), holdMs: 10).forwardedAt)
        pipeline.clearAgent()
    }

    func testRTTWindowSurvivesLogAndFallsBackToPartialWindow() throws {
        let server = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        XCTAssertGreaterThanOrEqual(server, 0)
        defer { close(server) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        XCTAssertEqual(withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(server, $0, length) } }, 0)
        XCTAssertEqual(withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(server, $0, &length) } }, 0)
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(server, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let key = Data(repeating: 7, count: 32)
        let queue = DispatchQueue(label: "test.udp")
        let transport = try UDPControllerTransport(host: "127.0.0.1", port: Int(UInt16(bigEndian: address.sin_port)), key: key, version: 2, queue: queue)
        XCTAssertEqual(queue.sync { transport.metrics }, TransportMetrics(kind: "udp-v2", rtt: nil))

        func roundTrip() {
            queue.sync { try? transport.send(.neutral) }
            var buffer = [UInt8](repeating: 0, count: 128)
            var peer = sockaddr_storage(); var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = withUnsafeMutablePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(server, &buffer, buffer.count, 0, $0, &peerLength) } }
            XCTAssertGreaterThan(count, 8)
            let sequence = buffer[..<8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            let ack = UDPControllerTransport.ack(sequence: sequence, key: key)
            _ = ack.withUnsafeBytes { bytes in withUnsafePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(server, bytes.baseAddress, bytes.count, 0, $0, peerLength) } } }
        }
        func waitForSamples(_ predicate: () -> Bool) {
            let deadline = Date().addingTimeInterval(2)
            while !predicate() && Date() < deadline { usleep(1000) }
        }
        roundTrip()
        waitForSamples { queue.sync { transport.metrics.rtt?.samples == 1 } }
        let partial = try XCTUnwrap(queue.sync { transport.metrics.rtt })
        XCTAssertEqual(partial.samples, 1)

        // Completing a window logs and clears samples; the completed window stays readable.
        queue.sync { transport.rttWindowSeconds = 0 }
        roundTrip()
        waitForSamples { queue.sync { transport.rttSamples.isEmpty } }
        let window = try XCTUnwrap(queue.sync { transport.metrics.rtt })
        XCTAssertEqual(window.samples, 2)
        XCTAssertLessThanOrEqual(window.p50Ms, window.p99Ms)
        XCTAssertLessThanOrEqual(window.p99Ms, window.maxMs)
        XCTAssertEqual(queue.sync { transport.rttSamples.count }, 0)
        XCTAssertEqual(queue.sync { transport.metrics.rtt }, window)
    }

    func testSessionTransportMetricsDefaultIsNil() {
        XCTAssertNil(RecordingControllerSession().transportMetrics())
        XCTAssertNil(PiControlBridge().transportMetrics())
    }
}
