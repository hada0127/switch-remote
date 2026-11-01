import Foundation
import CryptoKit
import Darwin
import OSLog

/// RTT percentiles in milliseconds; `windowEndUptime` is `ProcessInfo.systemUptime` seconds.
struct RTTWindow: Equatable { let samples: Int; let p50Ms, p99Ms, maxMs: Double; let windowEndUptime: Double }
struct TransportMetrics: Equatable { let kind: String; let rtt: RTTWindow? }

/// Per-SSH-session authenticated datagrams: uint64 sequence, JSON state, SHA256 HMAC.
/// Newer Pis answer each datagram with an authenticated ack used only to log RTT.
final class UDPControllerTransport {
    private var descriptor: Int32 = -1
    private let key: Data
    private var sequence: UInt64 = 0
    private let version: Int
    // Acks are read on `queue`; callers send on the same queue, so this state needs no lock.
    private var reader: DispatchSourceRead?
    private var sentAt = [(sequence: UInt64, time: Double)](repeating: (0, 0), count: 1024)
    private(set) var rttSamples: [Double] = []
    private var lastRTTLog = ProcessInfo.processInfo.systemUptime
    private var lastWindow: RTTWindow?
    /// Internal for tests.
    var rttWindowSeconds = 5.0
    private let logger = Logger(subsystem: "net.tarucy.videogamefilter.native", category: "ControllerInput")
    static func packet(payload: Data, sequence: UInt64, key: Data) -> Data {
        var number = sequence.bigEndian
        var data = withUnsafeBytes(of: &number) { Data($0) }
        data.append(payload)
        data.append(contentsOf: HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
        return data
    }
    static func ack(sequence: UInt64, key: Data) -> Data {
        var number = sequence.bigEndian
        var data = withUnsafeBytes(of: &number) { Data($0) }
        data.append(contentsOf: Array("VGFA".utf8))
        data.append(contentsOf: HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
        return data
    }
    static func ackSequence(_ data: Data, key: Data) -> UInt64? {
        let bytes = Array(data)
        guard bytes.count == 44, Array(bytes[8..<12]) == Array("VGFA".utf8),
              HMAC<SHA256>.isValidAuthenticationCode(bytes[12...], authenticating: bytes[..<12], using: SymmetricKey(data: key))
        else { return nil }
        return bytes[..<8].reduce(0) { $0 << 8 | UInt64($1) }
    }
    /// Nearest-rank p50/p99/max in milliseconds.
    static func rttSummary(_ samples: [Double]) -> (p50: Double, p99: Double, max: Double)? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        func rank(_ q: Double) -> Double { sorted[min(sorted.count - 1, max(0, Int((Double(sorted.count) * q).rounded(.up)) - 1))] * 1000 }
        return (rank(0.5), rank(0.99), sorted[sorted.count - 1] * 1000)
    }
    init(host: String, port: Int, key: Data, version: Int = 1, queue: DispatchQueue? = nil) throws {
        self.version = version
        guard (1...65535).contains(port), key.count == 32 else { throw NSError(domain: "UDP", code: 1, userInfo: [NSLocalizedDescriptionKey: "파이 UDP 연결 정보가 올바르지 않습니다."]) }
        self.key = key
        var hints = addrinfo()
        hints.ai_family = AF_INET; hints.ai_socktype = SOCK_DGRAM; hints.ai_protocol = IPPROTO_UDP
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let address = result else {
            throw NSError(domain: "UDP", code: 2, userInfo: [NSLocalizedDescriptionKey: "파이 IPv4 주소를 찾을 수 없습니다."])
        }
        defer { freeaddrinfo(address) }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw POSIXError(.ENOBUFS) }
        // Small interactive controller packets share Wi-Fi with streamed video.
        // Request responsive traffic treatment; unsupported QoS must not prevent play.
        var serviceType = Int32(NET_SERVICE_TYPE_RV)
        _ = setsockopt(fd, SOL_SOCKET, SO_NET_SERVICE_TYPE, &serviceType,
                       socklen_t(MemoryLayout.size(ofValue: serviceType)))
        guard fcntl(fd, F_SETFL, O_NONBLOCK) != -1,
              Darwin.connect(fd, address.pointee.ai_addr, address.pointee.ai_addrlen) == 0 else {
            let code = errno; close(fd); throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        descriptor = fd
        guard let queue else { return }
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        reader.setEventHandler { [weak self] in self?.readAcks() }
        reader.setCancelHandler { close(fd) }
        self.reader = reader; reader.resume()
    }
    /// Old Pis never ack and old apps never read: neither side depends on acks.
    func readAcks() {
        var buffer = [UInt8](repeating: 0, count: 64)
        for _ in 0..<64 {
            let count = Darwin.recv(descriptor, &buffer, buffer.count, MSG_DONTWAIT)
            guard count >= 0 else { break }
            let arrived = ProcessInfo.processInfo.systemUptime
            guard let acked = Self.ackSequence(Data(buffer[..<count]), key: key) else { continue }
            let slot = Int(acked % UInt64(sentAt.count))
            guard sentAt[slot].sequence == acked else { continue }
            sentAt[slot].sequence = 0
            if rttSamples.count < 4096 { rttSamples.append(arrived - sentAt[slot].time) }
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastRTTLog >= rttWindowSeconds, let rtt = Self.rttSummary(rttSamples) {
            lastRTTLog = now
            lastWindow = RTTWindow(samples: rttSamples.count, p50Ms: rtt.p50, p99Ms: rtt.p99, maxMs: rtt.max, windowEndUptime: now)
            logger.info("Input RTT: samples=\(self.rttSamples.count), p50_ms=\(rtt.p50), p99_ms=\(rtt.p99), max_ms=\(rtt.max)")
            rttSamples.removeAll(keepingCapacity: true)
        }
    }
    /// The last completed 5 s window, else the current partial one. Call on the ack queue.
    var metrics: TransportMetrics {
        var rtt = lastWindow
        if rtt == nil, let partial = Self.rttSummary(rttSamples) {
            rtt = RTTWindow(samples: rttSamples.count, p50Ms: partial.p50, p99Ms: partial.p99, maxMs: partial.max,
                            windowEndUptime: ProcessInfo.processInfo.systemUptime)
        }
        return TransportMetrics(kind: version == 2 ? "udp-v2" : "udp-v1", rtt: rtt)
    }
    func send(_ value: ControllerInput) throws {
        try send(version == 2 ? Self.binaryInputPayload(value) : JSONEncoder().encode(value))
    }
    func send(_ value: ControllerInput, sequence: UInt64) throws {
        try send(version == 2 ? Self.binaryInputPayload(value) : JSONEncoder().encode(value), sequence: sequence)
    }
    static func binaryInputPayload(_ value: ControllerInput) -> Data {
        let names = ["A","B","X","Y","L","R","ZL","ZR","PLUS","MINUS","HOME","CAPTURE","L_STICK_PRESS","R_STICK_PRESS","DPAD_UP","DPAD_DOWN","DPAD_LEFT","DPAD_RIGHT"]
        var flags: UInt32 = 0
        for (index, name) in names.enumerated() where value.buttons.contains(name) { flags |= 1 << index }
        var data = Data("VGF2".utf8)
        for offset in 0..<4 { data.append(UInt8(truncatingIfNeeded: flags >> (offset * 8))) }
        for raw in [value.lx, value.ly, value.rx, value.ry] {
            let axis = raw.isFinite ? min(1, max(-1, raw)) : 0
            let word = UInt16(bitPattern: Int16((axis * (axis < 0 ? 32768 : 32767)).rounded()))
            data.append(UInt8(truncatingIfNeeded: word)); data.append(UInt8(truncatingIfNeeded: word >> 8))
        }
        return data
    }
    func send(_ payload: Data) throws {
        guard sequence < UInt64.max else { throw POSIXError(.EBADF) }
        try send(payload, sequence: sequence + 1)
    }
    private func send(_ payload: Data, sequence number: UInt64) throws {
        guard descriptor >= 0, number > sequence else { throw POSIXError(.EBADF) }
        sequence = number
        let data = Self.packet(payload: payload, sequence: number, key: key)
        let sent = ProcessInfo.processInfo.systemUptime
        let count = data.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }
        if reader != nil && count == data.count { sentAt[Int(number % UInt64(sentAt.count))] = (number, sent) }
        // Loss, route changes, ICMP and the local-network permission prompt are
        // transient. The next full state repairs loss; SSH/Pi own timeouts.
        if count < 0 && [EBADF, EINVAL, EMSGSIZE].contains(errno) {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
    deinit {
        if let reader { reader.cancel() } else if descriptor >= 0 { close(descriptor) }
    }
}
