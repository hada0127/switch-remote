import Foundation
import CryptoKit
import Security

/// Adds first-boot setup to a Raspberry Pi Imager-prepared boot partition.
/// Wi-Fi/account settings remain owned by Imager. No disk formatting occurs here.
enum PiProvisioner {
    static func prepare(boot: URL, resourceDirectory: URL? = nil, supportDirectory: URL? = nil, beforeCommit: (() throws -> Void)? = nil) throws -> PiEnrollment {
        let fm = FileManager.default
        let command = boot.appendingPathComponent("cmdline.txt")
        guard fm.fileExists(atPath: command.path), fm.fileExists(atPath: boot.appendingPathComponent("config.txt").path),
              let resources = resourceDirectory ?? Bundle.main.resourceURL?.appendingPathComponent("ControllerBridge"),
              fm.fileExists(atPath: resources.appendingPathComponent("firstboot.sh").path) else {
            throw error("Raspberry Pi Imager로 준비한 bootfs 파티션을 선택하세요.")
        }
        let target = boot.appendingPathComponent("vgf-controller")
        guard !fm.fileExists(atPath: target.path) else { throw error("이 SD는 이미 준비되어 있습니다. 저장된 등록 정보로 연결하세요.") }
        let createdNames = ["vgf-controller", "vgf-firstboot.sh", "vgf-previous-run.txt", "vgf-cmdline-original.txt", "cmdline.txt.vgf-serial-backup"]
        guard createdNames.allSatisfy({ !fm.fileExists(atPath: boot.appendingPathComponent($0).path) }) else { throw error("기존 파이 준비 파일이 있습니다. 등록 정보를 먼저 확인하세요.") }
        let original = try String(contentsOf: command, encoding: .utf8)
        let bootConfig = boot.appendingPathComponent("config.txt")
        let originalConfig = try String(contentsOf: bootConfig, encoding: .utf8)
        var arguments = original.split(whereSeparator: \.isWhitespace).map(String.init)
        let previous = arguments.filter { $0.hasPrefix("systemd.run=") }.map { String($0.dropFirst("systemd.run=".count)) }
        guard previous.count <= 1, previous.allSatisfy({ $0.hasPrefix("/boot/") && !$0.contains("\n") }) else { throw error("기존 첫 부팅 설정을 확인할 수 없습니다.") }
        let temporary = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temporary) }
        let payload = temporary.appendingPathComponent("payload")
        try fm.createDirectory(at: payload, withIntermediateDirectories: true)
        for name in ["native", "install.sh", "install_identity.py", "vendor"] {
            try fm.copyItem(at: resources.appendingPathComponent(name), to: payload.appendingPathComponent(name))
        }
        let identity = payload.appendingPathComponent("identity")
        try fm.createDirectory(at: identity, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let id = UUID().uuidString.lowercased()
        let pin = String(format: "%06d", Int.random(in: 0..<1_000_000))
        let key = identity.appendingPathComponent("server.key")
        let certificate = identity.appendingPathComponent("server.crt")
        _ = try runOpenSSL(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "3650", "-keyout", key.path, "-out", certificate.path, "-subj", "/CN=vgf-" + id])
        let der = try runOpenSSL(["x509", "-in", certificate.path, "-outform", "DER"])
        let digest: (Data) -> String = { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        var secret = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, secret.count, &secret) == errSecSuccess else { throw error("등록 키를 생성할 수 없습니다.") }
        let config: [String: Any] = ["id": id, "secret": secret.map { String(format: "%02x", $0) }.joined(),
                                    "pin_hash": digest(Data((id + ":" + pin).utf8)), "paired": false]
        try JSONSerialization.data(withJSONObject: config).write(to: identity.appendingPathComponent("device.json"))
        let receipt = PiEnrollment(id: id, name: "Video Game Filter Pi", fingerprint: digest(der), client: UUID().uuidString.lowercased(), pin: pin)
        let support = supportDirectory ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VideoGameFilter")
        try fm.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let pending = support.appendingPathComponent("pending-pi-enrollment.json")
        guard !fm.fileExists(atPath: pending.path) else { throw error("저장 대기 중인 파이 등록 정보가 있습니다. 앱을 다시 열어 복구한 뒤 SD를 준비하세요.") }
        // Preserve registration before changing the SD, even if the app exits.
        try JSONEncoder().encode(receipt).write(to: pending, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pending.path)
        do {
            try fm.copyItem(at: payload, to: target)
            try fm.copyItem(at: resources.appendingPathComponent("firstboot.sh"), to: boot.appendingPathComponent("vgf-firstboot.sh"))
            if let previous = previous.first { try previous.write(to: boot.appendingPathComponent("vgf-previous-run.txt"), atomically: true, encoding: .utf8) }
            try original.write(to: boot.appendingPathComponent("vgf-cmdline-original.txt"), atomically: true, encoding: .utf8)
            let rollbackArguments = arguments.filter { !$0.hasPrefix("systemd.run=") && !$0.hasPrefix("systemd.run_success_action=") && !$0.hasPrefix("systemd.unit=") }
            try (rollbackArguments.joined(separator: " ") + "\n").write(to: boot.appendingPathComponent("cmdline.txt.vgf-serial-backup"), atomically: true, encoding: .utf8)
            arguments.removeAll { $0.hasPrefix("systemd.run=") || $0.hasPrefix("systemd.run_success_action=") || $0.hasPrefix("systemd.unit=") || $0.hasPrefix("console=serial0,") }
            arguments += ["systemd.run=/boot/firmware/vgf-firstboot.sh", "systemd.run_success_action=reboot", "systemd.unit=kernel-command-line.target"]
            let lines = originalConfig.split(separator: "\n")
            var settings: [String] = []
            if !lines.contains("dtoverlay=dwc2,dr_mode=peripheral") { settings.append("dtoverlay=dwc2,dr_mode=peripheral") }
            if !lines.contains("enable_uart=1") { settings.append("enable_uart=1") }
            if !lines.contains("core_freq=250") { settings.append("core_freq=250") }
            if !settings.isEmpty {
                try (originalConfig + "\n[all]\n# Video Game Filter USB controller\n" + settings.joined(separator: "\n") + "\n").write(to: bootConfig, atomically: true, encoding: .utf8)
            }
            try beforeCommit?()
            try (arguments.joined(separator: " ") + "\n").write(to: command, atomically: true, encoding: .utf8)
        } catch {
            try? original.write(to: command, atomically: true, encoding: .utf8)
            try? originalConfig.write(to: bootConfig, atomically: true, encoding: .utf8)
            for name in createdNames { try? fm.removeItem(at: boot.appendingPathComponent(name)) }
            try? fm.removeItem(at: pending)
            throw error
        }
        return receipt
    }
    private static func runOpenSSL(_ arguments: [String]) throws -> Data {
        let task = Process(); let output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/openssl"); task.arguments = arguments
        task.standardOutput = output; task.standardError = FileHandle.nullDevice
        try task.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw error("파이 인증서를 생성할 수 없습니다.") }
        return data
    }
    private static func error(_ message: String) -> NSError { NSError(domain: "PiProvisioning", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
