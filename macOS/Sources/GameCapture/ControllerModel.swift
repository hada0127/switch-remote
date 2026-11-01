import AppKit
import GameController
import SwiftUI
import OSLog
import AgentControlProtocol

@MainActor final class ControllerModel: ObservableObject {
    @Published private(set) var controllers: [GCController] = []
    @Published var selected = "" { didSet { configureInputHandlers(reset: true); configureMoonlight() } }
    var pickerSelection: String {
        selected.isEmpty && UserDefaults.standard.string(forKey: "controller.source") == "gamepad" ? "saved-gamepad" : selected
    }
    @Published private(set) var foundPis: [DiscoveredPi] = []
    @Published var selectedPi = "" { didSet { if oldValue != selectedPi { disconnect(manual: false); reconnectIfPossible() } } }
    @Published var automatic = true { didSet { UserDefaults.standard.set(automatic, forKey: "pi.automatic"); if automatic { reconnectIfPossible() } else { disconnect(manual: false) } } }
    @Published private(set) var preparing = false
    @Published private(set) var preparationMessage = ""
    private let deviceStore: PiDeviceStore
    private let controllerProvider: () -> [GCController]
    private var preferredPi = ""
    static let moonlightID = "moonlight"
    @Published private(set) var moonlightError = ""
    private var moonlight: MoonlightReceiver?
    /// Internal for tests.
    let inputPipeline = ControllerInputPipeline()
    private var inputGeneration = UUID()
    private var allowAutomaticInput = true
    private let discovery = PiDiscovery()
    private var retry: Task<Void, Never>?
    private var pairingRequested = false
    private var reconnectAfterUSBAction = false
    private var reconnectOrigin: UUID?
    /// A source choice is an intent, independent of transient gamepad availability.
    private var pendingSourceUSBAction: String?
    private var lastRequestedUSBAction: String?
    private var sourceUSBRequestInFlight: String?
    private var piDetached: Bool?
    private let logger = Logger(subsystem: "net.tarucy.videogamefilter.native", category: "Controller")
    private var loggedState = ""
    @Published var positional = false { didSet { UserDefaults.standard.set(positional, forKey: "controller.positional"); inputPipeline.setPositional(positional) } }
    @Published private(set) var status = "연결 안 됨"
    @Published private(set) var detail = ""
    @Published private(set) var usbState = "unavailable"
    @Published private(set) var running = false
    @Published private(set) var connected = false
    /// Raw backend reported with the last "connected" state ("usb" or a Bluetooth name).
    private(set) var backend: String?
    let liveInput = ControllerLiveInput()
    private var activity: NSObjectProtocol?
    private var bridge: ControllerSession?
    private var activeEndpoint: DiscoveredPi?
    private var generation = UUID()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var ids: [ObjectIdentifier: String] = [:]
    var canConnect: Bool { foundPis.contains { $0.id == selectedPi } && deviceStore.devices.contains { $0.id == selectedPi } }
    var hasSavedPi: Bool { !deviceStore.devices.isEmpty }
    func id(_ controller: GCController) -> String { ids[ObjectIdentifier(controller)] ?? "" }

    init(startDiscovery: Bool = true, controllerProvider: @escaping () -> [GCController] = GCController.controllers, store: PiDeviceStore? = nil) {
        self.deviceStore = store ?? PiDeviceStore()
        self.controllerProvider = controllerProvider
        positional = UserDefaults.standard.bool(forKey: "controller.positional")
        inputPipeline.setPositional(positional)
        status = "연결 안 됨"
        GCController.shouldMonitorBackgroundEvents = false
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        inputPipeline.setApplicationActive(NSApp?.isActive == true)
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willResignActiveNotification, object: nil, queue: .main) { [inputPipeline] _ in
            inputPipeline.setApplicationActive(false)
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [inputPipeline] _ in
            inputPipeline.setApplicationActive(true)
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self, inputPipeline] _ in
            inputPipeline.select(nil, remote: false)
            Task { @MainActor in self?.disconnect(manual: false) }
        })
        if UserDefaults.standard.bool(forKey: "controller.moonlight") {
            selected = Self.moonlightID; allowAutomaticInput = false
            configureInputHandlers(reset: true); configureMoonlight()
        }
        if UserDefaults.standard.string(forKey: "controller.source") == "none" { allowAutomaticInput = false }
        pendingSourceUSBAction = UserDefaults.standard.string(forKey: "controller.source") == "none" ? "detach" : "attach"
        refresh()
        automatic = UserDefaults.standard.object(forKey: "pi.automatic") as? Bool ?? true
        preferredPi = UserDefaults.standard.string(forKey: "pi.selected") ?? deviceStore.devices.first?.id ?? ""
        selectedPi = deviceStore.devices.first(where: { $0.id == preferredPi })?.id ?? deviceStore.devices.first?.id ?? ""
        discovery.onChange = { [weak self] devices in
            guard let self else { return }
            self.foundPis = devices
            if let active = self.activeEndpoint, let updated = devices.first(where: { $0.id == active.id }),
               updated.host != active.host || updated.port != active.port {
                self.disconnect(manual: false)
            }
            let available = devices.filter { d in self.deviceStore.devices.contains { $0.id == d.id } }
            if let choice = Self.effectivePi(preferred: self.preferredPi, current: self.selectedPi, available: available.map(\.id)), choice != self.selectedPi { self.selectedPi = choice }
            self.reconnectIfPossible()
        }
        discovery.onError = { [weak self] message in self?.detail = message }
        if startDiscovery { DispatchQueue.main.async { [weak self] in self?.discovery.start() } }
        // This timer is presentation only. Gameplay never waits for the UI loop.
        let ticker = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let value = self.inputPipeline.displayValue
                if self.liveInput.value != value { self.liveInput.value = value }
            }
        }
        timer = ticker; RunLoop.main.add(ticker, forMode: .common)
    }
    deinit { timer?.invalidate(); inputPipeline.setSession(nil); observers.forEach(NotificationCenter.default.removeObserver); bridge?.stop() }
    func refresh() {
        controllers = controllerProvider().filter { $0.extendedGamepad != nil }
        for c in controllers where ids[ObjectIdentifier(c)] == nil { ids[ObjectIdentifier(c)] = UUID().uuidString }
        ids = ids.filter { key, _ in controllers.contains { ObjectIdentifier($0) == key } }
        if !selected.isEmpty && selected != Self.moonlightID && !controllers.contains(where: { id($0) == selected }) { selected = "" }
        if allowAutomaticInput, let saved = UserDefaults.standard.string(forKey: "controller.gamepad"),
           let match = controllers.first(where: { $0.vendorName == saved }), selected != id(match) { selected = id(match) }
        if allowAutomaticInput && selected.isEmpty {
            let saved = UserDefaults.standard.string(forKey: "controller.gamepad")
            if let match = controllers.first(where: { $0.vendorName == saved }) ?? controllers.first { selected = id(match) }
        }
        configureInputHandlers()
    }
    func selectController(_ id: String) {
        let source = id.isEmpty ? "none" : (id == Self.moonlightID ? "moonlight" : "gamepad")
        if let gamepad = controllers.first(where: { self.id($0) == id }) {
            UserDefaults.standard.set(gamepad.vendorName, forKey: "controller.gamepad")
        }
        setSource(source, selectedID: id)
    }
    func selectSource(_ source: String) -> Result<[String: Any], AgentError> {
        guard ["none", "gamepad", "moonlight"].contains(source) else {
            return .failure(AgentError(.badRequest, "source must be none, gamepad or moonlight"))
        }
        let saved = UserDefaults.standard.string(forKey: "controller.gamepad")
        let gamepad = controllers.first(where: { $0.vendorName == saved }) ?? controllers.first
        let id = source == "moonlight" ? Self.moonlightID : (source == "gamepad" ? gamepad.map { self.id($0) } ?? "" : "")
        setSource(source, selectedID: id)
        return .success(["source": source, "usbActionPending": pendingSourceUSBAction != nil])
    }
    private func setSource(_ source: String, selectedID: String) {
        UserDefaults.standard.set(source == "moonlight", forKey: "controller.moonlight")
        UserDefaults.standard.set(source, forKey: "controller.source")
        allowAutomaticInput = source == "gamepad"; selected = selectedID
        pendingSourceUSBAction = source == "none" ? "detach" : "attach"
        applySourceUSBAction()
    }
    func selectPi(_ id: String) {
        preferredPi = id
        UserDefaults.standard.set(id, forKey: "pi.selected")
        selectedPi = id
    }
    static func effectivePi(preferred: String, current: String, available: [String]) -> String? {
        if available.contains(preferred) { return preferred }
        if available.contains(current) { return current }
        return available.first
    }
    static func shouldClearReconnectIntent(origin: UUID?, current: UUID, connected: Bool) -> Bool {
        connected && origin != nil && origin != current
    }
    private func configureMoonlight() {
        moonlight?.stop(); moonlight = nil; moonlightError = ""
        guard selected == Self.moonlightID else { return }
        let receiver = MoonlightReceiver(), generation = inputGeneration
        receiver.onPacket = { [inputPipeline] packet in
            inputPipeline.receive(packet, generation: generation)
        }
        do { try receiver.start(); moonlight = receiver }
        catch { moonlightError = error.localizedDescription }
    }
    private func configureInputHandlers(reset: Bool = false) {
        inputGeneration = inputPipeline.select(controllers.first(where: { id($0) == selected }), remote: selected == Self.moonlightID, reset: reset)
    }
    private func reconnectIfPossible() {
        guard automatic, !running, canConnect, retry == nil else { return }
        connect()
    }
    func connect(pair: Bool = false) {
        if pair { pairingRequested = true; if running { disconnect(manual: false) } }
        guard !running, let endpoint = foundPis.first(where: { $0.id == selectedPi }),
              let device = deviceStore.devices.first(where: { $0.id == selectedPi }) else { return }
        if UserDefaults.standard.string(forKey: "controller.source") == "none" { pendingSourceUSBAction = "detach" }
        retry?.cancel(); retry = nil
        let token = UUID(); generation = token
        let transport = PiControlBridge(); bridge = transport; activeEndpoint = endpoint
        transport.onUSBState = { [weak self] value in Task { @MainActor in self?.receiveUSBState(value, from: token) } }
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Forward game controller input to Raspberry Pi")
        logger.notice("Starting Pi connection")
        running = true; connected = false; status = "파이에 자동 연결 중…"; detail = ""
        transport.onMessage = { [weak self] state, message in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                if self.loggedState != state {
                    self.loggedState = state
                    self.logger.notice("Pi state: \(state, privacy: .public)")
                    if let message { self.logger.error("Pi connection detail: \(message, privacy: .public)") }
                }
                self.setLinkConnected(state == "connected", backend: message)
                if ["connected", "connecting", "reconnecting", "detached"].contains(state) {
                    self.piDetached = state == "detached"
                    if self.piDetached == true && self.sourceUSBRequestInFlight == "detach" { self.sourceUSBRequestInFlight = nil }
                    self.applySourceUSBAction()
                }
                if self.connected {
                    self.pairingRequested = false
                    if Self.shouldClearReconnectIntent(origin: self.reconnectOrigin, current: token, connected: true) {
                        self.reconnectAfterUSBAction = false; self.reconnectOrigin = nil
                    }
                }
                if state == "error" {
                    self.disconnect(manual: false); self.status = "다시 연결 대기 중"; self.detail = message ?? ""
                    if self.automatic || self.pairingRequested || self.reconnectAfterUSBAction {
                        self.retry = Task { @MainActor [weak self] in
                            do { try await Task.sleep(for: .seconds(5)) } catch { return }
                            self?.retry = nil; self?.discovery.refresh()
                            if self?.pairingRequested == true || self?.reconnectAfterUSBAction == true { self?.connect() } else { self?.reconnectIfPossible() }
                        }
                    }
                } else {
                    self.status = state == "connected" ? "스위치 연결됨 · " + (message == "usb" ? "USB" : "Bluetooth") :
                        (state == "detached" ? (UserDefaults.standard.string(forKey: "controller.source") == "none" ? "USB 연결 해제됨 · 입력 사용 안 함" : "USB 연결 해제됨") :
                        (state == "enrolled" ? "파이 등록 완료" : "스위치 연결 대기 중…"))
                }
            }
        }
        transport.send(.neutral); transport.start(device: device, endpoint: endpoint, pair: pairingRequested)
        inputPipeline.setSession(transport)
    }
    /// Any connected → not-connected transition drops the agent hold (neutral edge), so a
    /// reconnect on the same session can never resume an old agent input.
    func setLinkConnected(_ value: Bool, backend: String?) {
        if connected && !value { inputPipeline.clearAgent() }
        connected = value
        self.backend = value ? backend : nil
    }
    func receiveUSBState(_ value: String, from token: UUID) {
        guard generation == token else { return }
        usbState = value
    }
    static func sourceUSBAction(for intent: String?, detached: Bool?, lastRequested: String? = nil) -> String? {
        guard let intent, let detached else { return nil }
        if let lastRequested, lastRequested != intent { return intent }
        if intent == "detach" { return detached ? nil : "detach" }
        return detached ? "attach" : nil
    }
    static func shouldDeferSourceUSBAction(intent: String, lastRequested: String?) -> Bool {
        lastRequested == "attach" && intent == "detach"
    }
    private func applySourceUSBAction() {
        guard let pendingSourceUSBAction, running, usbState != "unavailable" else { return }
        // Attach ends the Pi session; send the newest choice on the replacement session.
        if Self.shouldDeferSourceUSBAction(intent: pendingSourceUSBAction, lastRequested: lastRequestedUSBAction) { return }
        guard let piDetached else { return }
        let action = Self.sourceUSBAction(for: pendingSourceUSBAction, detached: piDetached, lastRequested: lastRequestedUSBAction)
        if let action {
            guard case .success = usbAction(action) else { return }
            sourceUSBRequestInFlight = action
        }
        self.pendingSourceUSBAction = nil
    }
    var usbStatusText: String {
        let state = usbState == "not attached" ? "연결 해제됨" : (usbState == "configured" ? "연결됨" : usbState)
        if running && pendingSourceUSBAction == "detach" { return "USB: 연결 해제 대기 중 (\(state))" }
        if running && pendingSourceUSBAction == "attach" { return "USB: 다시 연결 대기 중 (\(state))" }
        if sourceUSBRequestInFlight == "detach" { return "USB: 연결 해제 요청됨 (\(state))" }
        if sourceUSBRequestInFlight == "attach" { return "USB: 다시 연결 요청됨 (\(state))" }
        return "USB: \(state)"
    }
    func disconnect(manual: Bool = true) {
        if manual { pairingRequested = false; reconnectAfterUSBAction = false; reconnectOrigin = nil; automatic = false }
        retry?.cancel(); retry = nil
        generation = UUID(); inputPipeline.setSession(nil); bridge?.stop(); bridge = nil; activeEndpoint = nil
        lastRequestedUSBAction = nil; sourceUSBRequestInFlight = nil; piDetached = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        running = false; connected = false; backend = nil; liveInput.value = .neutral; status = "연결 안 됨"
        usbState = "unavailable"
    }
    func usbAction(_ action: String) -> Result<[String: Any], AgentError> {
        guard action == "detach" || action == "attach" else { return .failure(AgentError(.badRequest, "invalid USB action")) }
        guard running, usbState != "unavailable", let bridge = bridge as? PiControlBridge else { return .failure(AgentError(.notConnected, "Pi control session is not ready")) }
        if action == "detach" { inputPipeline.clearAgent(); bridge.send(.neutral); setLinkConnected(false, backend: nil) }
        if action == "attach" { pairingRequested = false; reconnectAfterUSBAction = true; reconnectOrigin = generation }
        lastRequestedUSBAction = action
        bridge.controlUSB(action)
        return .success(["requested": action])
    }
    func press(_ buttons: [String]) {
        guard connected else { return }
        inputPipeline.press(buttons)
    }
    // MARK: agent control (local socket; see AgentControlServer)

    /// Controller, metrics and agent sections of the agent `status` result. No hosts, keys or tokens.
    func agentStatus() -> [String: Any] {
        let source = UserDefaults.standard.string(forKey: "controller.source") ?? (selected == Self.moonlightID ? "moonlight" : (selected.isEmpty ? "none" : "gamepad"))
        let transport = running ? bridge?.transportMetrics() : nil
        let metrics = inputPipeline.metrics
        var rtt: Any = NSNull()
        if let window = transport?.rtt {
            rtt = ["samples": window.samples, "p50Ms": window.p50Ms, "p99Ms": window.p99Ms, "maxMs": window.maxMs, "windowEndUptime": window.windowEndUptime]
        }
        return [
            "controller": ["source": source, "piRunning": running, "connected": connected,
                           "usbState": usbState,
                           "backend": connected ? (backend == "usb" ? "usb" : "bluetooth") : NSNull(),
                           "transport": transport?.kind ?? NSNull()] as [String: Any],
            "metrics": ["forwardedChanges": metrics.forwardedChanges, "maxForwardDelayMs": metrics.maxForwardDelayMS, "rtt": rtt] as [String: Any],
            "agent": ["holdUntil": inputPipeline.agentHoldUntil ?? NSNull()] as [String: Any]
        ]
    }

    /// Agent input works while the app is in the background, but only with a live Switch link.
    func agentInput(_ args: AgentInputArgs) -> Result<[String: Any], AgentError> {
        guard connected else { return .failure(AgentError(.notConnected, "the Switch controller link is not connected")) }
        let value = ControllerInput(buttons: args.buttons, lx: Float(args.lx), ly: Float(args.ly), rx: Float(args.rx), ry: Float(args.ry))
        let result = inputPipeline.setAgent(value, holdMs: args.holdMs)
        return .success(["forwardedAt": result.forwardedAt ?? NSNull(), "until": result.until])
    }

    func agentRelease() -> [String: Any] {
        inputPipeline.clearAgent()
        return ["released": true]
    }

    func prepareSD() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        panel.message = "Raspberry Pi Imager에서 Bookworm/Trixie 이상 OS와 Wi-Fi를 설정해 구운 SD의 bootfs 파티션을 선택하세요."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        preparing = true; preparationMessage = "SD와 자동 연결 정보를 준비하는 중…"
        Task.detached { [weak self] in
            do {
                let receipt = try PiProvisioner.prepare(boot: url)
                let data = try JSONEncoder().encode(receipt)
                await MainActor.run {
                    guard let self else { return }
                    do {
                        try self.deviceStore.enroll(data)
                        self.selectPi(receipt.id); self.automatic = true
                        self.preparationMessage = "SD 준비 완료. 등록 정보는 맥에 저장했습니다. SD를 안전하게 추출해 파이에 넣고 전원을 켜세요. 첫 설치에는 몇 분 걸릴 수 있습니다."
                    } catch { self.preparationMessage = "등록 정보 저장 실패: \(error.localizedDescription)" }
                    self.preparing = false
                }
            } catch {
                await MainActor.run { self?.preparing = false; self?.preparationMessage = error.localizedDescription }
            }
        }
    }

}

struct ControllerSettingsView: View {
    @ObservedObject var model: ControllerModel
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 28) {
            controllerSection("입력 장치") {
                ClassicPicker(title: "입력 장치", selection: Binding(get: { model.pickerSelection }, set: {
                    if $0 == "saved-gamepad" { _ = model.selectSource("gamepad") } else { model.selectController($0) }
                }),
                              options: [("", "입력 사용 안 함")] + (model.pickerSelection == "saved-gamepad" ? [("saved-gamepad", "저장된 게임패드 · 연결 대기")] : []) + [(ControllerModel.moonlightID, "문라이트 · 선샤인")] + model.controllers.map { (model.id($0), $0.vendorName ?? "Controller") }, enabled: true)
                    .frame(height: 72)
                if model.selected == ControllerModel.moonlightID {
                    Text("연결된 문라이트의 첫 번째 패드로 조작합니다. 앱이 뒤에 있어도 입력을 전달합니다.").font(AppFonts.font(22)).foregroundStyle(.secondary)
                    if !model.moonlightError.isEmpty { Text(model.moonlightError).foregroundStyle(.red) }
                }
                if model.controllers.isEmpty && model.selected != ControllerModel.moonlightID { Text("컨트롤러를 맥에 연결하세요.").foregroundStyle(.secondary) }
                Toggle("A/B · X/Y 맞바꾸기", isOn: $model.positional).toggleStyle(.switch).frame(minHeight: 72)
                Text("스위치 계열 패드는 보통 끈 상태로 사용합니다. 맥에 연결된 패드는 앱이 활성화된 동안만 입력을 보냅니다.").font(AppFonts.font(22)).foregroundStyle(.secondary)
                ControllerInputReadout(model: model.liveInput)
            }
            controllerSection("라즈베리파이 · 자동 연결") {
                Toggle("네트워크에서 찾으면 자동 연결", isOn: $model.automatic).toggleStyle(.switch).frame(minHeight: 72)
                ClassicPicker(title: "파이", selection: Binding(get: { model.selectedPi }, set: { model.selectPi($0) }),
                              options: [("", "검색 중…")] + ((!model.selectedPi.isEmpty && !model.foundPis.contains(where: { $0.id == model.selectedPi })) ? [(model.selectedPi, "등록된 파이 · 오프라인")] : []) + model.foundPis.map { ($0.id, $0.name) }, enabled: !model.running)
                    .frame(height: 72)
                if model.foundPis.isEmpty { Text("같은 네트워크에서 파이를 찾고 있습니다.").font(AppFonts.font(22)).foregroundStyle(.secondary) }
                HStack {
                    Button("USB 연결 해제") { _ = model.usbAction("detach") }.disabled(!model.running || model.usbState == "unavailable")
                    Button("USB 다시 연결") { _ = model.usbAction("attach") }.disabled(!model.running || model.usbState == "unavailable")
                }
                HStack {
                    Button("파이 세션 연결") { model.connect() }.disabled(model.running || !model.canConnect)
                    Button("파이 세션 연결 해제") { model.disconnect() }.disabled(!model.running)
                    Button("스위치 새로 페어링") { model.connect(pair: true) }.disabled(!model.canConnect)
                }
                Text(model.status)
                Text(model.usbStatusText)
                if !model.detail.isEmpty { Text(model.detail).font(AppFonts.font(22)).foregroundStyle(.red).textSelection(.enabled) }
                Button(model.preparing ? "SD 준비 중…" : "새 파이 SD 준비…") { model.prepareSD() }.disabled(model.preparing)
                if !model.preparationMessage.isEmpty { Text(model.preparationMessage).font(AppFonts.font(22)).textSelection(.enabled) }
                Text("SD 준비 때 등록 정보를 이 맥의 키체인에 저장합니다. 이후에는 전원만 켜면 자동 연결됩니다. 로컬 네트워크 접근을 허용해주세요.").font(AppFonts.font(22)).foregroundStyle(.secondary)
                Text("블루투스 최초 연결: 스위치의 컨트롤러 → 잡는 방법/순서 변경을 여세요. USB 연결: 파이의 USB 데이터 포트를 독에 연결하세요. 유선 입력이 안 되면 스위치의 Pro 컨트롤러 유선 통신 설정도 확인하세요. 새로 페어링은 블루투스 연결용입니다.").font(AppFonts.font(22)).foregroundStyle(.secondary)
            }
            controllerSection("스위치") {
                Text("스위치 2 깨우기: 현재 미지원. 파이가 에뮬레이션하는 기존 Pro 컨트롤러로는 스위치 2의 슬립을 해제할 수 없습니다. 본체를 켠 뒤 다시 연결하세요.").font(AppFonts.font(22)).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(28).padding(.bottom, 48)
        }
        .font(AppFonts.font(28))
    }
    private func controllerSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(title).font(AppFonts.font(26)).foregroundStyle(.secondary)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor final class ControllerLiveInput: ObservableObject {
    @Published var value = ControllerInput.neutral
}
struct ControllerInputReadout: View {
    @ObservedObject var model: ControllerLiveInput
    var body: some View {
        Text(model.value.buttons.isEmpty ? "누른 버튼 없음" : model.value.buttons.joined(separator: " · ")).font(AppFonts.font(22))
        Text(String(format: "L  %.2f, %.2f    R  %.2f, %.2f", model.value.lx, model.value.ly, model.value.rx, model.value.ry)).monospacedDigit().font(AppFonts.font(22))
    }
}
