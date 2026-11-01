import Foundation
import GameController
import OSLog

/// Times are `ProcessInfo.systemUptime` seconds. `forwardedAt` is nil when the change was
/// coalesced into the 2 ms analog window or no session is attached.
struct AgentHoldResult: Equatable { let forwardedAt: Double?; let until: Double }

/// GameController callbacks, remote packets and heartbeats share this queue.
/// Rendering and SwiftUI may stall the main thread without delaying gameplay.
final class ControllerInputPipeline: @unchecked Sendable {
    let queue = DispatchQueue(label: "net.tarucy.controller.input", qos: .userInteractive)
    private var controller: GCController?
    private var remote = false
    private var source = UUID()
    private var local = ControllerInput.neutral
    private var moonlight = MoonlightState()
    private var active = false
    private var positional = false
    private var session: ControllerSession?
    private var pulse: (buttons: [String], until: Double)?
    /// Agent (local IPC) input is its own layer: it ignores the focus gate but is always
    /// time-limited, and selection/session changes drop it.
    private var agent: (value: ControllerInput, until: Double)?
    private var agentWork: DispatchWorkItem?
    private var agentGeneration = 0
    private var agentUntilDisplay: Double?
    private var tickForwardedAt: Double?
    private var lastSent: ControllerInput?
    /// Last change-driven send. Heartbeats never move it, so they cannot delay a stick edge.
    private var lastChangeSend = -Double.infinity
    private var axisWork: DispatchWorkItem?
    static let analogInterval = 0.002
    private var timer: DispatchSourceTimer?
    private let displayLock = NSLock()
    private var displayed = ControllerInput.neutral
    struct Metrics { var forwardedChanges = 0; var maxForwardDelayMS = 0.0 }
    private var measurements = Metrics()
    private var receivedAt: Double?
    private var lastMetricsLog = 0.0
    private let logger = Logger(subsystem: "net.tarucy.videogamefilter.native", category: "ControllerInput")

    var metrics: Metrics {
        displayLock.lock(); defer { displayLock.unlock() }
        return measurements
    }

    var displayValue: ControllerInput {
        displayLock.lock(); defer { displayLock.unlock() }
        return displayed
    }

    init(heartbeat: Bool = true) {
        if heartbeat {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.tick(heartbeat: true) }
            self.timer = timer; timer.resume()
        }
    }
    var agentHoldUntil: Double? {
        displayLock.lock(); defer { displayLock.unlock() }
        return agentUntilDisplay
    }

    deinit {
        if let controller { Self.setSystemGestures(controller, .enabled) }
        timer?.cancel(); axisWork?.cancel(); agentWork?.cancel()
    }

    private static func setSystemGestures(_ controller: GCController, _ state: GCControllerElement.SystemGestureState) {
        guard let pad = controller.extendedGamepad else { return }
        // Home and Xbox Share can be reserved by macOS. Menu/Options must also
        // remain available as Switch + and - while this is the selected source.
        pad.buttonHome?.preferredSystemGestureState = state
        (pad as? GCXboxGamepad)?.buttonShare?.preferredSystemGestureState = state
        pad.buttonMenu.preferredSystemGestureState = state
        pad.buttonOptions?.preferredSystemGestureState = state
    }

    @discardableResult
    func select(_ selected: GCController?, remote: Bool, reset: Bool = false) -> UUID {
        queue.sync {
            if controller !== selected || remote {
                if let controller { Self.setSystemGestures(controller, .enabled) }
            }
            if let selected { Self.setSystemGestures(selected, active && !remote ? .disabled : .enabled) }
            guard reset || controller !== selected || self.remote != remote else { return source }
            controller?.extendedGamepad?.valueChangedHandler = nil
            source = UUID(); controller = selected; self.remote = remote
            local = .neutral; moonlight = MoonlightState(); pulse = nil; dropAgent()
            axisWork?.cancel(); axisWork = nil; lastSent = nil; receivedAt = nil
            session?.send(.neutral)
            if let selected, let pad = selected.extendedGamepad {
                // The profile is mutable only on handlerQueue. Snapshot it here,
                // before another event can overwrite a short press/release edge.
                selected.handlerQueue = queue
                let generation = source
                pad.valueChangedHandler = { [weak self] pad, _ in
                    let received = ProcessInfo.processInfo.systemUptime
                    self?.updateLocal(ControllerInput.read(pad, positional: false), generation: generation, received: received)
                }
                local = ControllerInput.read(pad, positional: false)
            }
            tick()
            return source
        }
    }

    func updateLocal(_ value: ControllerInput, generation: UUID, received: Double = ProcessInfo.processInfo.systemUptime) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !remote, source == generation else { return }
        if local != value { receivedAt = received }
        local = value; tick()
    }

    func receive(_ packet: MoonlightPacket, generation: UUID) {
        // Timestamp before dispatch so waiting packets cannot refresh stale input.
        let received = ProcessInfo.processInfo.systemUptime
        queue.async { [weak self] in
            guard let self, self.remote, self.source == generation else { return }
            let previous = self.moonlight.current(at: received, swap: self.positional)
            self.moonlight.accept(packet, at: received)
            if self.moonlight.current(at: received, swap: self.positional) != previous { self.receivedAt = received }
            self.tick()
        }
    }

    func setApplicationActive(_ value: Bool) {
        queue.sync {
            active = value; receivedAt = nil
            if let controller { Self.setSystemGestures(controller, value && !remote ? .disabled : .enabled) }
            if !value { pulse = nil; local = .neutral }
            else if let pad = controller?.extendedGamepad { local = ControllerInput.read(pad, positional: false) }
            tick(heartbeat: true)
        }
    }
    func setPositional(_ value: Bool) {
        queue.sync { positional = value; receivedAt = nil; tick() }
    }
    func setSession(_ value: ControllerSession?) {
        queue.sync {
            session?.send(.neutral)
            session = value; lastSent = nil; pulse = nil; receivedAt = nil; dropAgent()
            axisWork?.cancel(); axisWork = nil
            value?.send(.neutral)
            tick()
        }
    }
    func press(_ buttons: [String]) {
        queue.sync {
            pulse = (buttons, ProcessInfo.processInfo.systemUptime + 0.15); receivedAt = nil
            tick()
        }
    }

    /// Replaces any current agent hold. The hold ends by itself at `until`.
    @discardableResult
    func setAgent(_ value: ControllerInput, holdMs: Int) -> AgentHoldResult {
        queue.sync {
            let until = ProcessInfo.processInfo.systemUptime + Double(max(1, holdMs)) / 1000
            dropAgent()
            agent = (value, until)
            displayLock.lock(); agentUntilDisplay = until; displayLock.unlock()
            let generation = agentGeneration
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.agentGeneration == generation, self.agent != nil else { return }
                self.dropAgent(); self.receivedAt = nil; self.tick()
            }
            agentWork = work
            queue.asyncAfter(deadline: .now() + Double(max(1, holdMs)) / 1000, execute: work)
            // Agent edges are not gamepad callbacks: keep them out of forward-delay metrics.
            receivedAt = nil; tickForwardedAt = nil
            tick()
            return AgentHoldResult(forwardedAt: tickForwardedAt, until: until)
        }
    }

    func clearAgent() {
        queue.sync {
            guard agent != nil else { return }
            dropAgent(); receivedAt = nil; tick()
        }
    }

    /// Runs on `queue`.
    private func dropAgent() {
        agentWork?.cancel(); agentWork = nil; agent = nil; agentGeneration += 1
        displayLock.lock(); agentUntilDisplay = nil; displayLock.unlock()
    }

    /// Internal for tests; runs on `queue`.
    func tick(heartbeat: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        var value = remote ? moonlight.current(at: now, swap: positional) : (active ? local : .neutral)
        if !remote && positional {
            value.buttons = value.buttons.map { ["A": "B", "B": "A", "X": "Y", "Y": "X"][$0] ?? $0 }
        }
        if let pulse {
            if active && pulse.until > now { value.buttons = Array(Set(value.buttons + pulse.buttons)) }
            else { self.pulse = nil }
        }
        if let agent {
            if agent.until > now {
                value.buttons = Array(Set(value.buttons + agent.value.buttons))
                if agent.value.lx != 0 { value.lx = agent.value.lx }
                if agent.value.ly != 0 { value.ly = agent.value.ly }
                if agent.value.rx != 0 { value.rx = agent.value.rx }
                if agent.value.ry != 0 { value.ry = agent.value.ry }
            } else { dropAgent() }
        }
        value.buttons.sort()
        displayLock.lock(); displayed = value; displayLock.unlock()
        guard let session, heartbeat || lastSent != value else { return }
        // Buttons and the first analog change after a quiet 2 ms go out at once; an analog-only
        // burst sends its latest state at the 2 ms boundary (at most 500 Hz).
        if !heartbeat && lastSent?.buttons == value.buttons && now - lastChangeSend < Self.analogInterval {
            if axisWork == nil {
                let work = DispatchWorkItem { [weak self] in self?.axisWork = nil; self?.tick() }
                axisWork = work
                queue.asyncAfter(deadline: .now() + (lastChangeSend + Self.analogInterval - now), execute: work)
            }
            return
        }
        let changed = lastSent != value
        lastSent = value
        if !heartbeat { lastChangeSend = now }
        session.send(value)
        tickForwardedAt = ProcessInfo.processInfo.systemUptime
        if changed, let receivedAt {
            let forwarded = ProcessInfo.processInfo.systemUptime
            displayLock.lock()
            measurements.forwardedChanges += 1
            measurements.maxForwardDelayMS = max(measurements.maxForwardDelayMS, (forwarded - receivedAt) * 1000)
            let summary = measurements
            displayLock.unlock()
            self.receivedAt = nil
            if forwarded - lastMetricsLog >= 5 {
                lastMetricsLog = forwarded
                logger.info("Input forwarding: changes=\(summary.forwardedChanges), max_callback_to_enqueue_ms=\(summary.maxForwardDelayMS)")
            }
        }
    }
}
