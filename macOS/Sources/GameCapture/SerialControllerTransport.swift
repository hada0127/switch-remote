import Foundation
import Darwin
import IOKit

/// GPIO UART wire format: a5 5a, length, big endian sequence, VGF2 state, CRC-16/CCITT-FALSE.
/// Length is 24 for input, 8 for an acknowledgment and 26 for a control frame. CRC covers length through payload.
enum SerialFrame {
    static func crc(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var value: UInt16 = 0xffff
        for byte in bytes {
            value ^= UInt16(byte) << 8
            for _ in 0..<8 { value = (value << 1) ^ ((value & 0x8000) == 0 ? 0 : 0x1021) }
        }
        return value
    }
    static func make(sequence: UInt64, input: ControllerInput) -> [UInt8] {
        var bytes: [UInt8] = [0xa5, 0x5a, 24]
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: sequence >> shift)) }
        bytes += UDPControllerTransport.binaryInputPayload(input)
        let check = crc(bytes[2...]); bytes += [UInt8(truncatingIfNeeded: check), UInt8(truncatingIfNeeded: check >> 8)]
        return bytes
    }
    static func ackSequence(_ bytes: [UInt8]) -> UInt64? {
        guard bytes.count == 13, bytes[0] == 0xa5, bytes[1] == 0x5a, bytes[2] == 8 else { return nil }
        let check = crc(bytes[2..<11])
        guard bytes[11] == UInt8(truncatingIfNeeded: check), bytes[12] == UInt8(truncatingIfNeeded: check >> 8) else { return nil }
        return bytes[3..<11].reduce(0) { ($0 << 8) | UInt64($1) }
    }
    static let controlLength: UInt8 = 26, controlSize = 31, controlBody = 25
    static func make(control type: UInt8, body: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = [0xa5, 0x5a, controlLength, type]
        bytes += SerialControl.body(body)
        let check = crc(bytes[2...]); bytes += [UInt8(truncatingIfNeeded: check), UInt8(truncatingIfNeeded: check >> 8)]
        return bytes
    }
    static func control(_ bytes: [UInt8]) -> (type: UInt8, body: [UInt8])? {
        guard bytes.count == controlSize, bytes[0] == 0xa5, bytes[1] == 0x5a, bytes[2] == controlLength else { return nil }
        let check = crc(bytes[2..<29])
        guard bytes[29] == UInt8(truncatingIfNeeded: check), bytes[30] == UInt8(truncatingIfNeeded: check >> 8) else { return nil }
        return (bytes[3], Array(bytes[4..<29]))
    }
}

enum SerialEvent: Equatable {
    case ack(UInt64)
    case control(UInt8, [UInt8])
}

/// Pi → Mac stream: 13-byte ACKs (LEN 8) and 31-byte control frames (LEN 26).
/// Anything else, including stray input frames (LEN 24), is skipped one byte at a time.
struct SerialFrameParser {
    private var received: [UInt8] = []
    mutating func feed(_ bytes: ArraySlice<UInt8>) -> [SerialEvent] {
        received += bytes
        var found: [SerialEvent] = []
        while received.count >= 3 {
            if received[0] != 0xa5 || received[1] != 0x5a { received.removeFirst(); continue }
            let size: Int
            switch received[2] {
            case 8: size = 13
            case SerialFrame.controlLength: size = SerialFrame.controlSize
            default: received.removeFirst(); continue
            }
            guard received.count >= size else { break }
            let frame = Array(received.prefix(size))
            if size == 13, let ack = SerialFrame.ackSequence(frame) { found.append(.ack(ack)); received.removeFirst(size) }
            else if size == SerialFrame.controlSize, let control = SerialFrame.control(frame) {
                found.append(.control(control.type, control.body)); received.removeFirst(size)
            } else { received.removeFirst() }
        }
        if received.count > 64 { received.removeFirst(received.count - 64) }
        return found
    }
}

/// Serial control protocol (LEN 26 frames). The cable is trusted physically: frames carry a CRC
/// only, so nothing secret (token, PIN, UDP key) ever crosses the UART.
enum SerialControl {
    static let version: UInt8 = 1
    static let hello: UInt8 = 0x01, usb: UInt8 = 0x02, bye: UInt8 = 0x03
    static let helloReply: UInt8 = 0x81, status: UInt8 = 0x82, usbResult: UInt8 = 0x83, piBye: UInt8 = 0x84
    static let states = ["starting", "connecting", "reconnecting", "connected", "detached"]

    static func body(_ bytes: [UInt8]) -> [UInt8] {
        Array((bytes + [UInt8](repeating: 0, count: SerialFrame.controlBody)).prefix(SerialFrame.controlBody))
    }
    static func bigEndian(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> (24 - 8 * UInt32($0))) } }
    static func readBigEndian(_ body: [UInt8], at offset: Int) -> UInt32 {
        body[offset..<offset + 4].reduce(0) { ($0 << 8) | UInt32($1) }
    }
    static func helloBody(nonce: UInt32) -> [UInt8] { body([version] + bigEndian(nonce)) }
    static func usbBody(id: UInt32, action: String) -> [UInt8] { body(bigEndian(id) + [action == "attach" ? 2 : 1]) }
    static func byeBody(nonce: UInt32) -> [UInt8] { body(bigEndian(nonce)) }
    static func hello(nonce: UInt32) -> [UInt8] { SerialFrame.make(control: Self.hello, body: helloBody(nonce: nonce)) }
    static func usb(id: UInt32, action: String) -> [UInt8] { SerialFrame.make(control: Self.usb, body: usbBody(id: id, action: action)) }
    static func bye(nonce: UInt32) -> [UInt8] { SerialFrame.make(control: Self.bye, body: byeBody(nonce: nonce)) }

    /// STATUS: state and backend use the same strings as the TLS `status` message.
    static func status(_ body: [UInt8]) -> (state: String, backend: String?, usbState: String?)? {
        guard body.count == SerialFrame.controlBody, Int(body[0]) < states.count else { return nil }
        let backend: String? = body[1] == 1 ? "usb" : (body[1] == 2 ? "bluetooth" : nil)
        let text = body[2..<18].prefix { $0 != 0 }
        let usbState = text.isEmpty ? nil : String(decoding: text, as: UTF8.self)
        return (states[Int(body[0])], backend, usbState)
    }
    static func helloReply(_ body: [UInt8]) -> (version: UInt8, result: UInt8, nonce: UInt32, id: UUID)? {
        guard body.count == SerialFrame.controlBody else { return nil }
        let b = Array(body[6..<22])
        let id = UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
        return (body[0], body[1], readBigEndian(body, at: 2), id)
    }
    static func usbResult(_ body: [UInt8]) -> (id: UInt32, accepted: Bool)? {
        guard body.count == SerialFrame.controlBody else { return nil }
        return (readBigEndian(body, at: 0), body[4] == 0)
    }
    static func piBye(_ body: [UInt8]) -> (nonce: UInt32, reason: UInt8)? {
        guard body.count == SerialFrame.controlBody else { return nil }
        return (readBigEndian(body, at: 0), body[4])
    }
}

final class SerialControllerTransport {
    private(set) var descriptor: Int32 = -1
    private var reader: DispatchSourceRead?
    private var parser = SerialFrameParser()
    /// Called on the transport queue for each valid control frame.
    var onControl: ((UInt8, [UInt8]) -> Void)?
    private var sentAt: [UInt64: Double] = [:]
    private(set) var lastAck = 0.0
    private(set) var rttSamples: [Double] = []
    private var lastRTTWindow: RTTWindow?
    private var lastRTTReset = ProcessInfo.processInfo.systemUptime
    private(set) var openedAt = ProcessInfo.processInfo.systemUptime
    private let onFailure: () -> Void
    private static func number(_ entry: io_registry_entry_t, _ key: String) -> Int? {
        (IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
    }
    private static func isFTDI(_ service: io_registry_entry_t) -> Bool {
        var entry = service
        for _ in 0..<8 {
            if number(entry, "idVendor") == 0x0403 && number(entry, "idProduct") == 0x6001 {
                if entry != service { IOObjectRelease(entry) }
                return true
            }
            var parent: io_registry_entry_t = 0
            if IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) != KERN_SUCCESS { break }
            if entry != service { IOObjectRelease(entry) }
            entry = parent
        }
        if entry != service { IOObjectRelease(entry) }
        return false
    }
    static func devicePath() -> String? {
        guard ProcessInfo.processInfo.environment["SWITCH_REMOTE_DISABLE_SERIAL"] != "1" else { return nil }
        if let explicit = ProcessInfo.processInfo.environment["SWITCH_REMOTE_SERIAL_PATH"],
           explicit.hasPrefix("/dev/cu.usbserial-") { return explicit }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOSerialBSDClient"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var paths: [String] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            if isFTDI(service), let path = IORegistryEntryCreateCFProperty(service, "IOCalloutDevice" as CFString,
                kCFAllocatorDefault, 0)?.takeRetainedValue() as? String, path.hasPrefix("/dev/cu.usbserial-") {
                paths.append(path)
            }
            IOObjectRelease(service)
        }
        return paths.sorted().first
    }
    init(path: String, queue: DispatchQueue, onFailure: @escaping () -> Void) throws {
        self.onFailure = onFailure
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var options = termios()
        guard tcgetattr(fd, &options) == 0 else { let code = errno; close(fd); throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        cfmakeraw(&options)
        _ = cfsetispeed(&options, speed_t(B115200)); _ = cfsetospeed(&options, speed_t(B115200))
        options.c_cflag |= tcflag_t(CLOCAL | CREAD)
        options.c_cflag &= ~tcflag_t(CRTSCTS)
        guard tcsetattr(fd, TCSANOW, &options) == 0, tcflush(fd, TCIOFLUSH) == 0 else {
            let code = errno; close(fd); throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        descriptor = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAcks() }
        source.setCancelHandler { close(fd) }
        reader = source; source.resume()
    }
    func send(_ input: ControllerInput, sequence: UInt64) throws {
        guard descriptor >= 0, sequence > 0 else { throw POSIXError(.EBADF) }
        let bytes = SerialFrame.make(sequence: sequence, input: input)
        let count = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        guard count == bytes.count else { throw POSIXError(.EIO) }
        sentAt[sequence] = ProcessInfo.processInfo.systemUptime
        if sentAt.count > 256, let oldest = sentAt.keys.min() { sentAt.removeValue(forKey: oldest) }
    }
    func sendControl(type: UInt8, body: [UInt8]) throws {
        guard descriptor >= 0 else { throw POSIXError(.EBADF) }
        let bytes = SerialFrame.make(control: type, body: body)
        let count = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        guard count == bytes.count else { throw POSIXError(.EIO) }
    }
    private func readAcks() {
        var chunk = [UInt8](repeating: 0, count: 128)
        let n = Darwin.read(descriptor, &chunk, chunk.count)
        if n < 0 { if errno != EAGAIN && errno != EWOULDBLOCK { onFailure() }; return }
        if n == 0 { onFailure(); return }
        for event in parser.feed(chunk[..<n]) {
            guard case .ack(let ack) = event else {
                if case .control(let type, let body) = event { onControl?(type, body) }
                continue
            }
            guard let sent = sentAt.removeValue(forKey: ack) else { continue }
            let now = ProcessInfo.processInfo.systemUptime
            lastAck = now
            if rttSamples.count < 1024 { rttSamples.append(now - sent) }
            if now - lastRTTReset >= 5, let summary = UDPControllerTransport.rttSummary(rttSamples) {
                lastRTTWindow = RTTWindow(samples: rttSamples.count, p50Ms: summary.p50, p99Ms: summary.p99,
                                           maxMs: summary.max, windowEndUptime: now)
                rttSamples.removeAll(keepingCapacity: true); lastRTTReset = now
            }
        }
    }
    var metrics: TransportMetrics {
        if let summary = UDPControllerTransport.rttSummary(rttSamples) {
            return TransportMetrics(kind: "serial", rtt: RTTWindow(samples: rttSamples.count, p50Ms: summary.p50,
                p99Ms: summary.p99, maxMs: summary.max, windowEndUptime: ProcessInfo.processInfo.systemUptime))
        }
        return TransportMetrics(kind: "serial", rtt: lastRTTWindow)
    }
    deinit { reader?.cancel() }
}
