import Foundation
import Security
import Combine
import OSLog

struct PairedPi: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var fingerprint: String
    var client: String
}
struct PiEnrollment: Codable {
    var id: String
    var name: String
    var fingerprint: String
    var client: String
    var pin: String
    var device: PairedPi { PairedPi(id: id, name: name, fingerprint: fingerprint, client: client) }
}

enum PiKeychain {
    private static let service = "net.tarucy.videogamefilter.pi"
    static func read(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ value: String, account: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        let update = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        return SecItemAdd(query.merging(update) { _, new in new } as CFDictionary, nil) == errSecSuccess
    }
    static func remove(_ account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }
}

@MainActor final class PiDeviceStore: ObservableObject {
    @Published private(set) var devices: [PairedPi] = []
    static var directory: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VideoGameFilter") }
    private let storage: URL
    private let saveCredential: (String, String) -> Bool
    private var file: URL { storage.appendingPathComponent("paired-pis.json") }
    init(directory: URL? = nil, credentialSave: ((String, String) -> Bool)? = nil) {
        storage = directory ?? Self.directory
        saveCredential = credentialSave ?? { PiKeychain.save($0, account: $1) }
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([PairedPi].self, from: data) { devices = saved }
        let pending = storage.appendingPathComponent("pending-pi-enrollment.json")
        if let data = try? Data(contentsOf: pending), (try? enroll(data)) != nil { try? FileManager.default.removeItem(at: pending) }
    }
    @discardableResult func enroll(_ data: Data) throws -> PiEnrollment {
        let entry = try JSONDecoder().decode(PiEnrollment.self, from: data)
        guard UUID(uuidString: entry.id) != nil, UUID(uuidString: entry.client) != nil,
              entry.fingerprint.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              entry.pin.range(of: "^[0-9]{6}$", options: .regularExpression) != nil else {
            throw NSError(domain: "Pi", code: 1, userInfo: [NSLocalizedDescriptionKey: "파이 등록 정보 형식이 올바르지 않습니다."])
        }
        if let old = devices.first(where: { $0.id == entry.id }), old != entry.device {
            throw NSError(domain: "Pi", code: 2, userInfo: [NSLocalizedDescriptionKey: "이미 등록된 파이와 인증 정보가 다릅니다."])
        }
        guard saveCredential(entry.pin, entry.id + ".pin") else {
            throw NSError(domain: "Pi", code: 3, userInfo: [NSLocalizedDescriptionKey: "키체인에 파이 등록 정보를 저장할 수 없습니다."])
        }
        var updated = devices.filter { $0.id != entry.id }; updated.append(entry.device)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(updated).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        devices = updated
        let pending = storage.appendingPathComponent("pending-pi-enrollment.json")
        if let data = try? Data(contentsOf: pending), let saved = try? JSONDecoder().decode(PiEnrollment.self, from: data), saved.id == entry.id { try? FileManager.default.removeItem(at: pending) }
        return entry
    }
}

struct DiscoveredPi: Identifiable, Equatable {
    var id: String
    var name: String
    var host: String
    var port: Int
}
@MainActor final class PiDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let browser = NetServiceBrowser()
    private let logger = Logger(subsystem: "net.tarucy.videogamefilter.native", category: "PiDiscovery")
    private let makeResolver: (String, String, String) -> NetService
    private let scheduleRetry: (TimeInterval, @escaping () -> Void) -> Void
    private var services: [NetService] = []
    private var devices: [String: DiscoveredPi] = [:]
    private var restartPending = false
    private var resolving = Set<String>()
    private var resolveAttempts: [String: UUID] = [:]
    private var pendingResolve = Set<String>()
    var onChange: (([DiscoveredPi]) -> Void)?
    var onError: ((String) -> Void)?
    init(makeResolver: @escaping (String, String, String) -> NetService = { NetService(domain: $0, type: $1, name: $2) },
         scheduleRetry: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, action in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
         }) {
        self.makeResolver = makeResolver; self.scheduleRetry = scheduleRetry
        super.init(); browser.delegate = self
    }
    func start() {
        logger.notice("Starting local Pi discovery")
        browser.schedule(in: .main, forMode: .common)
        browser.searchForServices(ofType: "_vgf-controller._tcp.", inDomain: "local.")
    }
    func refresh() { for service in services { resolve(service) } }
    private func resolve(_ service: NetService) {
        guard !resolving.contains(service.name), !pendingResolve.contains(service.name) else { return }
        let attempt = UUID()
        resolving.insert(service.name); resolveAttempts[service.name] = attempt
        service.resolve(withTimeout: 10)
        // NetService can find a Bonjour service yet never call either resolve delegate method.
        // Replace the stalled resolver so discovery recovers without restarting the app.
        scheduleRetry(12) { [weak self, weak service] in
            guard let self, let service, self.resolveAttempts[service.name] == attempt,
                  self.resolving.contains(service.name),
                  let index = self.services.firstIndex(where: { $0 === service }) else { return }
            self.logger.error("Pi service resolution stalled; retrying")
            self.resolving.remove(service.name)
            self.resolveAttempts.removeValue(forKey: service.name)
            service.delegate = nil
            service.stop()
            let replacement = self.makeResolver(service.domain, service.type, service.name)
            replacement.delegate = self
            replacement.schedule(in: .main, forMode: .common)
            self.services[index] = replacement
            self.resolve(replacement)
        }
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        logger.notice("Found Pi service")
        if services.contains(where: { $0.name == service.name && $0.type == service.type && $0.domain == service.domain }) { return }
        // Own the resolver independently from the browser-delivered service.
        let resolver = makeResolver(service.domain, service.type, service.name)
        services.append(resolver); resolver.delegate = self; resolver.schedule(in: .main, forMode: .common); resolve(resolver)
    }
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard services.contains(where: { $0 === sender }) else { return }
        logger.notice("Resolved Pi service addresses: \(sender.addresses?.count ?? 0)")
        resolving.remove(sender.name)
        resolveAttempts.removeValue(forKey: sender.name)
        guard let txt = sender.txtRecordData(), let idData = NetService.dictionary(fromTXTRecord: txt)["id"],
              let id = String(data: idData, encoding: .utf8), UUID(uuidString: id) != nil else { return }
        var hosts: [String] = []
        for data in sender.addresses ?? [] {
            let host: String? = data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress, bytes.count >= MemoryLayout<sockaddr_in>.size else { return nil }
                let address = base.assumingMemoryBound(to: sockaddr.self)
                guard address.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(address, socklen_t(bytes.count), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
                return String(cString: buffer)
            }
            if let host { hosts.append(host) }
        }
        if let host = Self.preferredHost(hosts) {
            logger.notice("Publishing resolved Pi: \(host, privacy: .public)")
            devices[sender.name] = DiscoveredPi(id: id, name: sender.name, host: host, port: sender.port)
            onChange?(Array(devices.values).sorted { $0.name < $1.name })
        }
    }
    // Some DNS configurations also return a public wildcard answer for .local.
    // Prefer the LAN address when the resolver subsequently supplies it.
    static func preferredHost(_ hosts: [String]) -> String? {
        func rank(_ host: String) -> Int {
            let bytes = host.split(separator: ".").compactMap { Int($0) }
            guard bytes.count == 4 else { return 2 }
            return bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1])) ||
                (bytes[0] == 192 && bytes[1] == 168) || (bytes[0] == 169 && bytes[1] == 254) ? 0 : 1
        }
        return hosts.sorted { rank($0) == rank($1) ? $0 < $1 : rank($0) < rank($1) }.first
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        resolving.remove(service.name); pendingResolve.remove(service.name)
        resolveAttempts.removeValue(forKey: service.name)
        services.filter { $0.name == service.name && $0.type == service.type && $0.domain == service.domain }.forEach { $0.stop() }
        devices.removeValue(forKey: service.name)
        services.removeAll { $0.name == service.name && $0.type == service.type && $0.domain == service.domain }
        onChange?(Array(devices.values).sorted { $0.name < $1.name })
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        if !restartPending {
            restartPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self else { return }; self.restartPending = false; self.browser.stop(); self.start(); self.refresh()
            }
        }
        onError?("파이를 검색할 수 없습니다. 시스템 설정에서 로컬 네트워크 접근을 허용하세요. (\(errorDict[NetService.errorCode] ?? 0))")
    }
    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        guard services.contains(where: { $0 === sender }) else { return }
        resolving.remove(sender.name)
        resolveAttempts.removeValue(forKey: sender.name)
        guard services.contains(sender), pendingResolve.insert(sender.name).inserted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak sender] in
            guard let self, let sender, self.services.contains(sender), self.pendingResolve.remove(sender.name) != nil else { return }
            self.resolve(sender)
        }
        onError?("파이 주소를 확인하지 못했습니다. 같은 네트워크인지 확인하세요. (\(errorDict[NetService.errorCode] ?? 0))")
    }
}
