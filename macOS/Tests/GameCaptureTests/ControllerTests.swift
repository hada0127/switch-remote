import XCTest
import GameController
@testable import GameCapture

private final class SilentPiService: NetService {
    var resolveCount = 0
    var stopCount = 0
    var testAddresses: [Data]?
    var testTXT: Data?
    override var addresses: [Data]? { testAddresses }
    override var port: Int { 24872 }
    override func txtRecordData() -> Data? { testTXT }
    override func resolve(withTimeout timeout: TimeInterval) { resolveCount += 1 }
    override func stop() { stopCount += 1 }
    override func schedule(in aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {}
}

final class ControllerTests: XCTestCase {
    @MainActor func testDiscoveryPrefersLANOverWildcardDNS() {
        XCTAssertEqual(PiDiscovery.preferredHost(["218.38.137.27", "192.168.0.139"]), "192.168.0.139")
        XCTAssertEqual(PiDiscovery.preferredHost(["192.168.0.139", "218.38.137.27"]), "192.168.0.139")
        XCTAssertNil(PiDiscovery.preferredHost([]))
    }
    @MainActor func testSilentPiResolveIsReplacedAndRemovedServiceCannotRetry() {
        let id = UUID().uuidString
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("192.168.0.139"))
        let addressData = withUnsafeBytes(of: &address) { Data($0) }
        var resolvers: [SilentPiService] = []
        var timers: [() -> Void] = []
        let discovery = PiDiscovery(makeResolver: { domain, type, name in
            let service = SilentPiService(domain: domain, type: type, name: name)
            service.testAddresses = [addressData]
            service.testTXT = NetService.data(fromTXTRecord: ["id": Data(id.utf8)])
            resolvers.append(service)
            return service
        }, scheduleRetry: { delay, action in
            XCTAssertEqual(delay, 12)
            timers.append(action)
        })
        var published: [DiscoveredPi] = []
        discovery.onChange = { published = $0 }
        let browser = NetServiceBrowser()
        let found = NetService(domain: "local.", type: "_vgf-controller._tcp.", name: "switch-pi")
        discovery.netServiceBrowser(browser, didFind: found, moreComing: false)
        XCTAssertEqual(resolvers.count, 1)
        XCTAssertEqual(resolvers[0].resolveCount, 1)
        timers.removeFirst()()
        XCTAssertEqual(resolvers.count, 2)
        XCTAssertEqual(resolvers[0].stopCount, 1)
        XCTAssertEqual(resolvers[1].resolveCount, 1)
        discovery.netServiceDidResolveAddress(resolvers[0])
        XCTAssertTrue(published.isEmpty)
        discovery.netServiceDidResolveAddress(resolvers[1])
        XCTAssertEqual(published.first?.id, id)
        XCTAssertEqual(published.first?.host, "192.168.0.139")
        discovery.netServiceBrowser(browser, didRemove: found, moreComing: false)
        XCTAssertTrue(published.isEmpty)
        timers.removeFirst()()
        XCTAssertEqual(resolvers.count, 2)
        let removedBeforeResolve = NetService(domain: "local.", type: "_vgf-controller._tcp.", name: "another-pi")
        discovery.netServiceBrowser(browser, didFind: removedBeforeResolve, moreComing: false)
        XCTAssertEqual(resolvers.count, 3)
        discovery.netServiceBrowser(browser, didRemove: removedBeforeResolve, moreComing: false)
        XCTAssertEqual(resolvers[2].stopCount, 1)
        timers.removeFirst()()
        XCTAssertEqual(resolvers.count, 3)
    }
    func testDeadzoneAndEndpoints() {
        XCTAssertEqual(ControllerInput.axis(0.07), 0)
        XCTAssertEqual(ControllerInput.axis(-1), -1)
        XCTAssertEqual(ControllerInput.axis(1.3), 1)
        XCTAssertEqual(ControllerInput.axis(.nan), 0)
        XCTAssertEqual(ControllerInput.axis(0.54), 0.5, accuracy: 0.0001)
    }
    func testFaceButtonPositions() {
        XCTAssertEqual(ControllerInput.faceButtons(south: true, east: false, west: true, north: false, positional: true), ["B", "Y"])
        XCTAssertEqual(ControllerInput.faceButtons(south: true, east: false, west: true, north: false, positional: false), ["A", "X"])
    }
    func testSSHRejectsOptionAndShellInjection() {
        for host in ["-oProxyCommand=bad", "host;touch /tmp/bad", "host\nother", ""] {
            XCTAssertFalse(PiConnection(host: host, user: "pi", key: "/tmp/key").valid)
        }
        let config = PiConnection(host: "192.168.0.139", user: "hada", key: "/tmp/key with spaces")
        XCTAssertTrue(config.valid)
        XCTAssertTrue(config.arguments(pair: false).contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(config.arguments(pair: true).last!.hasSuffix(" --pair"))
    }
    func testUDPMatchesPythonAuthenticationVector() {
        let payload = Data(#"{"type":"input","buttons":["A"],"lx":0.5}"#.utf8)
        let packet = UDPControllerTransport.packet(payload: payload, sequence: 42, key: Data(0..<32))
        XCTAssertEqual(packet.map { String(format: "%02x", $0) }.joined(), "000000000000002a7b2274797065223a22696e707574222c22627574746f6e73223a5b2241225d2c226c78223a302e357d1ee60064e3838073b555b5f5c66e1f5bb1c3633f60aab4fbe30192d9209887b4")
    }
    func testSDPreparationPreservesImagerSetupAndReceipt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let boot = root.appendingPathComponent("boot"), support = root.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: boot, withIntermediateDirectories: true)
        try Data().write(to: boot.appendingPathComponent("config.txt"))
        let original = "console=serial0,115200 console=tty1 root=PARTUUID=example rootwait systemd.run=/boot/firmware/firstrun.sh systemd.run_success_action=reboot systemd.unit=kernel-command-line.target\n"
        try original.write(to: boot.appendingPathComponent("cmdline.txt"), atomically: true, encoding: .utf8)
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("controller")
        let receipt = try PiProvisioner.prepare(boot: boot, resourceDirectory: resources, supportDirectory: support)
        XCTAssertEqual(try String(contentsOf: boot.appendingPathComponent("vgf-previous-run.txt")), "/boot/firmware/firstrun.sh")
        XCTAssertEqual(try String(contentsOf: boot.appendingPathComponent("vgf-cmdline-original.txt")), original)
        let rollbackCommand = try String(contentsOf: boot.appendingPathComponent("cmdline.txt.vgf-serial-backup"))
        XCTAssertTrue(rollbackCommand.contains("console=serial0,115200"))
        XCTAssertFalse(rollbackCommand.contains("systemd.run="))
        let command = try String(contentsOf: boot.appendingPathComponent("cmdline.txt"))
        XCTAssertTrue(command.contains("root=PARTUUID=example"))
        XCTAssertFalse(command.contains("console=serial0,"))
        XCTAssertTrue(command.contains("systemd.run=/boot/firmware/vgf-firstboot.sh"))
        let saved = try JSONDecoder().decode(PiEnrollment.self, from: Data(contentsOf: support.appendingPathComponent("pending-pi-enrollment.json")))
        let bootSettings = try String(contentsOf: boot.appendingPathComponent("config.txt"))
        XCTAssertTrue(bootSettings.contains("[all]\n# Video Game Filter USB controller\ndtoverlay=dwc2,dr_mode=peripheral"))
        XCTAssertTrue(bootSettings.contains("enable_uart=1\ncore_freq=250"))
        XCTAssertEqual(saved.id, receipt.id)
        XCTAssertEqual(saved.pin, receipt.pin)
        XCTAssertEqual(saved.fingerprint.count, 64)
        XCTAssertThrowsError(try PiProvisioner.prepare(boot: boot, resourceDirectory: resources, supportDirectory: support))
        XCTAssertEqual(try String(contentsOf: boot.appendingPathComponent("cmdline.txt")), command)
    }
    @MainActor func testPendingEnrollmentRecoveryAndAutomaticGamepadHandlers() throws {
        let originalSource = UserDefaults.standard.object(forKey: "controller.source")
        UserDefaults.standard.set("gamepad", forKey: "controller.source")
        defer { if let originalSource { UserDefaults.standard.set(originalSource, forKey: "controller.source") }
                else { UserDefaults.standard.removeObject(forKey: "controller.source") } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let entry = PiEnrollment(id: UUID().uuidString, name: "test", fingerprint: String(repeating: "a", count: 64), client: UUID().uuidString, pin: "123456")
        let pending = root.appendingPathComponent("pending-pi-enrollment.json")
        try JSONEncoder().encode(entry).write(to: pending)
        var saved: [String: String] = [:]
        let store = PiDeviceStore(directory: root, credentialSave: { value, account in saved[account] = value; return true })
        XCTAssertEqual(store.devices.first?.id, entry.id)
        XCTAssertEqual(saved[entry.id + ".pin"], entry.pin)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
        var pads = [GCController.withExtendedGamepad()]
        let model = ControllerModel(startDiscovery: false, controllerProvider: { pads }, store: store)
        XCTAssertFalse(model.selected.isEmpty)
        XCTAssertNotNil(pads[0].extendedGamepad?.valueChangedHandler)
        pads = []; model.refresh(); XCTAssertTrue(model.selected.isEmpty)
        pads = [GCController.withExtendedGamepad()]; model.refresh()
        XCTAssertNotNil(pads[0].extendedGamepad?.valueChangedHandler)
        XCTAssertFalse(model.selected.isEmpty)
        model.selectController(""); model.refresh(); XCTAssertTrue(model.selected.isEmpty)
    }
    @MainActor func testOfflinePreferredPiUsesAvailableFallbackAndReturns() {
        XCTAssertEqual(ControllerModel.effectivePi(preferred: "saved", current: "saved", available: ["other"]), "other")
        XCTAssertEqual(ControllerModel.effectivePi(preferred: "saved", current: "other", available: ["other", "saved"]), "saved")
        XCTAssertNil(ControllerModel.effectivePi(preferred: "saved", current: "saved", available: []))
    }
    @MainActor func testUSBReconnectIntentSurvivesOldSessionStatus() {
        let old = UUID(), replacement = UUID()
        XCTAssertFalse(ControllerModel.shouldClearReconnectIntent(origin: old, current: old, connected: true))
        XCTAssertFalse(ControllerModel.shouldClearReconnectIntent(origin: old, current: replacement, connected: false))
        XCTAssertTrue(ControllerModel.shouldClearReconnectIntent(origin: old, current: replacement, connected: true))
    }
    @MainActor func testExplicitSourceUSBTransitions() {
        XCTAssertEqual(ControllerModel.sourceUSBAction(for: "detach", detached: false), "detach")
        XCTAssertNil(ControllerModel.sourceUSBAction(for: "detach", detached: true))
        XCTAssertEqual(ControllerModel.sourceUSBAction(for: "attach", detached: true), "attach")
        XCTAssertNil(ControllerModel.sourceUSBAction(for: "attach", detached: false))
        XCTAssertNil(ControllerModel.sourceUSBAction(for: "detach", detached: nil))
        XCTAssertNil(ControllerModel.sourceUSBAction(for: "attach", detached: nil))
        // The Pi's "not attached" USB state also occurs when undocked; session
        // detach state, rather than USB state, determines whether to reattach.
        XCTAssertEqual(ControllerModel.sourceUSBAction(for: "attach", detached: true, lastRequested: "detach"), "attach")
        XCTAssertEqual(ControllerModel.sourceUSBAction(for: "detach", detached: false, lastRequested: "attach"), "detach")
        XCTAssertTrue(ControllerModel.shouldDeferSourceUSBAction(intent: "detach", lastRequested: "attach"))
        XCTAssertFalse(ControllerModel.shouldDeferSourceUSBAction(intent: "attach", lastRequested: "detach"))
    }
    @MainActor func testSourceChoiceSurvivesUnavailableGamepad() {
        let originalSource = UserDefaults.standard.object(forKey: "controller.source")
        let originalGamepad = UserDefaults.standard.object(forKey: "controller.gamepad")
        let originalMoonlight = UserDefaults.standard.object(forKey: "controller.moonlight")
        defer {
            for (key, value) in [("controller.source", originalSource), ("controller.gamepad", originalGamepad), ("controller.moonlight", originalMoonlight)] {
                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        UserDefaults.standard.set("gamepad", forKey: "controller.source")
        UserDefaults.standard.set("saved pad", forKey: "controller.gamepad")
        let store = PiDeviceStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), credentialSave: { _, _ in true })
        let model = ControllerModel(startDiscovery: false, controllerProvider: { [] }, store: store)
        model.selectController("")
        XCTAssertEqual(model.pickerSelection, "")
        XCTAssertTrue(model.usbStatusText.contains("unavailable"))
        XCTAssertEqual(UserDefaults.standard.string(forKey: "controller.gamepad"), "saved pad")
        XCTAssertEqual((model.agentStatus()["controller"] as? [String: Any])?["source"] as? String, "none")
        guard case .success = model.selectSource("gamepad") else { return XCTFail("gamepad source rejected") }
        XCTAssertTrue(model.selected.isEmpty)
        XCTAssertEqual(model.pickerSelection, "saved-gamepad")
        XCTAssertEqual((model.agentStatus()["controller"] as? [String: Any])?["source"] as? String, "gamepad")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "controller.gamepad"), "saved pad")
        model.refresh()
        XCTAssertEqual((model.agentStatus()["controller"] as? [String: Any])?["source"] as? String, "gamepad")
    }
    @MainActor func testObsoleteSessionCannotPublishUSBState() {
        let store = PiDeviceStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), credentialSave: { _, _ in true })
        let model = ControllerModel(startDiscovery: false, controllerProvider: { [] }, store: store)
        model.receiveUSBState("configured", from: UUID())
        XCTAssertEqual(model.usbState, "unavailable")
    }
    func testSDCommitFailureRestoresOriginalFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let boot = root.appendingPathComponent("boot"), support = root.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: boot, withIntermediateDirectories: true)
        try Data().write(to: boot.appendingPathComponent("config.txt"))
        try "console=tty1 rootwait\n".write(to: boot.appendingPathComponent("cmdline.txt"), atomically: true, encoding: .utf8)
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("controller")
        XCTAssertThrowsError(try PiProvisioner.prepare(boot: boot, resourceDirectory: resources, supportDirectory: support, beforeCommit: { throw NSError(domain: "InjectedDiskFull", code: 1) }))
        XCTAssertEqual(try String(contentsOf: boot.appendingPathComponent("cmdline.txt")), "console=tty1 rootwait\n")
        XCTAssertEqual(try String(contentsOf: boot.appendingPathComponent("config.txt")), "")
        for name in ["vgf-controller", "vgf-firstboot.sh", "vgf-previous-run.txt", "vgf-cmdline-original.txt", "cmdline.txt.vgf-serial-backup"] { XCTAssertFalse(FileManager.default.fileExists(atPath: boot.appendingPathComponent(name).path)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("pending-pi-enrollment.json").path))
    }
}
