import Foundation
import Darwin
import IOKit

/// GPIO UART wire format: a5 5a, length, big endian sequence, VGF2 state, CRC-16/CCITT-FALSE.
/// Length is 24 for input and 8 for an acknowledgment. CRC covers length through payload.
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
}

struct SerialAckParser {
    private var received: [UInt8] = []
    mutating func feed(_ bytes: ArraySlice<UInt8>) -> [UInt64] {
        received += bytes
        var found: [UInt64] = []
        while received.count >= 3 {
            if received[0] != 0xa5 || received[1] != 0x5a { received.removeFirst(); continue }
            if received[2] != 8 { received.removeFirst(); continue }
            guard received.count >= 13 else { break }
            let frame = Array(received.prefix(13))
            if let ack = SerialFrame.ackSequence(frame) { found.append(ack); received.removeFirst(13) }
            else { received.removeFirst() }
        }
        if received.count > 32 { received.removeFirst(received.count - 32) }
        return found
    }
}

final class SerialControllerTransport {
    private(set) var descriptor: Int32 = -1
    private var reader: DispatchSourceRead?
    private var parser = SerialAckParser()
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
    private func readAcks() {
        var chunk = [UInt8](repeating: 0, count: 128)
        let n = Darwin.read(descriptor, &chunk, chunk.count)
        if n < 0 { if errno != EAGAIN && errno != EWOULDBLOCK { onFailure() }; return }
        if n == 0 { onFailure(); return }
        for ack in parser.feed(chunk[..<n]) {
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
