import XCTest
@testable import GameCapture

final class SerialFrameTests: XCTestCase {
    func testUSBControlWaitsForAuthenticatedTransport() {
        XCTAssertFalse(PiControlBridge.canControlUSB(active: true, hasAuthenticatedTransport: false))
        XCTAssertFalse(PiControlBridge.canControlUSB(active: false, hasAuthenticatedTransport: true))
        XCTAssertTrue(PiControlBridge.canControlUSB(active: true, hasAuthenticatedTransport: true))
    }
    func testSerialHealthAndFallbackDecision() {
        XCTAssertFalse(PiControlBridge.serialHealthy(openedAt: 10, lastAck: 0, now: 10.05))
        XCTAssertFalse(PiControlBridge.serialHealthy(openedAt: 10, lastAck: 9, now: 10.05))
        XCTAssertTrue(PiControlBridge.serialHealthy(openedAt: 10, lastAck: 10.02, now: 10.08))
        XCTAssertFalse(PiControlBridge.serialHealthy(openedAt: 10, lastAck: 10.02, now: 10.13))
    }
    func testFrameAndAckCRC() {
        XCTAssertEqual(SerialFrame.crc(Array("123456789".utf8)[...]), 0x29b1)
        let input = ControllerInput(buttons: ["A", "HOME"], lx: -1, ly: 1, rx: 0, ry: 0.5)
        let bytes = SerialFrame.make(sequence: 9, input: input)
        XCTAssertEqual(bytes.count, 29)
        XCTAssertEqual(Array(bytes.prefix(3)), [0xa5, 0x5a, 24])
        XCTAssertEqual(Array(bytes[11..<27]), Array(UDPControllerTransport.binaryInputPayload(input)))
        let crc = SerialFrame.crc(bytes[2..<27])
        XCTAssertEqual(bytes[27], UInt8(truncatingIfNeeded: crc))
        XCTAssertEqual(bytes[28], UInt8(truncatingIfNeeded: crc >> 8))
        var ack: [UInt8] = [0xa5, 0x5a, 8, 0, 0, 0, 0, 0, 0, 0, 9]
        let check = SerialFrame.crc(ack[2...])
        ack += [UInt8(truncatingIfNeeded: check), UInt8(truncatingIfNeeded: check >> 8)]
        XCTAssertEqual(SerialFrame.ackSequence(ack), 9)
        var parser = SerialAckParser()
        XCTAssertTrue(parser.feed(([0xff] + Array(ack.prefix(6)))[...]).isEmpty)
        XCTAssertEqual(parser.feed(ack[6...]), [9])
        ack[10] ^= 1
        XCTAssertNil(SerialFrame.ackSequence(ack))
        XCTAssertTrue(parser.feed(ack[...]).isEmpty)
    }
}
