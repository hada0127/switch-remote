import SwiftUI
import AVFoundation

@MainActor final class CaptureModel: ObservableObject {
    let engine = CaptureEngine()
    /// Newest raw frame for agent snapshots; filled on the capture frame queue.
    let frameTap = FrameTap()
    /// Last measured capture size and rate, for agent status.
    private(set) var frameInfo: (width: Int, height: Int, fps: Double)?
    let renderer: VideoRenderer?
    @Published var rendererError: String?
    @Published var videos: [AVCaptureDevice] = []
    @Published var audios: [AVCaptureDevice] = []
    @Published var videoID = ""
    @Published var audioID = ""
    @Published var modeID = -1
    @Published var modes: [VideoMode] = []
    @Published var busy = false
    @Published var running = false
    @Published var hasFrames = false
    @Published var status = "캡처카드를 선택하세요"
    @Published var measured = ""
    @Published var volume: Double = 0.7 { didSet { defaults.set(volume, forKey: "capture.volume"); engine.volume(muted ? 0 : Float(volume)) } }
    @Published var muted = false { didSet { defaults.set(muted, forKey: "capture.muted"); engine.volume(muted ? 0 : Float(volume)) } }
    @Published var controlsVisible = true
    private var observers: [NSObjectProtocol] = []
    private var generation = 0
    private var lastFrame = Date.distantPast
    private var timer: Timer?
    private let defaults: UserDefaults
    private var preferredVideo = ""
    private var preferredAudio = ""
    private var hasAudioPreference = false
    private var preferredMode = ""

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferredVideo = defaults.string(forKey: "capture.videoID") ?? ""
        preferredAudio = defaults.string(forKey: "capture.audioID") ?? ""
        hasAudioPreference = defaults.object(forKey: "capture.audioID") != nil
        preferredMode = defaults.string(forKey: "capture.mode") ?? ""
        if let saved = defaults.object(forKey: "capture.volume") as? Double { volume = min(1, max(0, saved.isFinite ? saved : 0.7)) }
        muted = defaults.object(forKey: "capture.muted") as? Bool ?? false
        do { renderer = try VideoRenderer() }
        catch { renderer = nil; rendererError = error.localizedDescription }
        renderer?.onError = { [weak self] message in
            DispatchQueue.main.async { self?.rendererError = message }
        }
        engine.onVideoFrame = { [renderer, frameTap] frame in frameTap.store(frame); renderer?.submit(frame) }
        engine.onFrames = { [weak self] width, height, rate in
            DispatchQueue.main.async {
                guard let self, self.running else { return }
                self.lastFrame = Date()
                self.hasFrames = true
                self.frameInfo = (Int(width), Int(height), rate)
                self.measured = "캡처 \(width) × \(height) · \(String(format: "%.1f", rate)) fps"
            }
        }
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: engine.session, queue: .main) { [weak self] note in
            let message = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? "캡처 장치에서 오류가 발생했습니다."
            Task { @MainActor in self?.stop(message: message) }
        })
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.running, Date().timeIntervalSince(self.lastFrame) > 3 else { return }
                self.hasFrames = false
                self.measured = ""
                self.status = "프레임 대기 중 · HDMI 연결과 다른 캡처 앱을 확인하세요"
            }
        }
        refresh()
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver); timer?.invalidate() }
    func refresh() {
        videos = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified).devices
        audios = AVCaptureDevice.DiscoverySession(deviceTypes: [.external, .microphone], mediaType: .audio, position: .unspecified).devices
        if !videoID.isEmpty && !videos.contains(where: { $0.uniqueID == videoID }) {
            stop(message: "캡처카드 연결이 해제됐습니다.")
            videoID = ""; modes = []; modeID = -1
        }
        if !audioID.isEmpty && !audios.contains(where: { $0.uniqueID == audioID }) {
            audioID = ""
            if running { stop(message: "오디오 장치 연결이 해제됐습니다. 소리 없이 다시 시작할 수 있습니다.") }
        }
        if videoID.isEmpty, let device = videos.first(where: { $0.uniqueID == preferredVideo }) ?? videos.first(where: { $0.localizedName.localizedCaseInsensitiveContains("HD60") }) ?? videos.first {
            videoID = device.uniqueID
            selectVideo()
        }
        if !busy && !preferredVideo.isEmpty && videoID != preferredVideo,
           videos.contains(where: { $0.uniqueID == preferredVideo }) {
            videoID = preferredVideo
            selectVideo()
            if running { stop(restart: true) }
        }
        if Self.shouldRestoreAudio(running: running, busy: busy, current: audioID, preferred: preferredAudio,
                                   available: audios.contains(where: { $0.uniqueID == preferredAudio })) { audioID = preferredAudio }
    }
    static func shouldRestoreAudio(running: Bool, busy: Bool, current: String, preferred: String, available: Bool) -> Bool {
        !running && !busy && available && !preferred.isEmpty && current != preferred
    }
    func selectVideo() {
        guard let device = videos.first(where: { $0.uniqueID == videoID }) else { modes = []; modeID = -1; return }
        modes = CaptureEngine.modes(for: device)
        // Prefer smooth 1080p for play; every supported resolution remains selectable.
        modeID = modes.first(where: { $0.preferenceKey == preferredMode })?.id ?? VideoMode.preferred(in: modes)?.id ?? -1
        if hasAudioPreference && preferredAudio.isEmpty { audioID = "" }
        else if let saved = audios.first(where: { $0.uniqueID == preferredAudio }) { audioID = saved.uniqueID }
        else if let matching = audios.first(where: { $0.uniqueID == device.uniqueID || $0.localizedName == device.localizedName }) { audioID = matching.uniqueID }
        else { audioID = "" }
    }
    func changeVideo(to id: String) {
        guard !busy else { return }
        videoID = id
        preferredVideo = id; defaults.set(id, forKey: "capture.videoID")
        selectVideo()
        running ? stop(restart: true) : start()
    }
    func changeAudio(to id: String) {
        guard !busy else { return }
        audioID = id
        preferredAudio = id; defaults.set(id, forKey: "capture.audioID")
        hasAudioPreference = true
        running ? stop(restart: true) : start()
    }
    func changeMode(to id: Int) {
        guard !busy else { return }
        modeID = id
        if let mode = modes.first(where: { $0.id == id }) { preferredMode = mode.preferenceKey; defaults.set(preferredMode, forKey: "capture.mode") }
        running ? stop(restart: true) : start()
    }
    func start() {
        guard !busy, !running, let device = videos.first(where: { $0.uniqueID == videoID }), let mode = modes.first(where: { $0.id == modeID }) else { return }
        let selectedAudio = audios.first { $0.uniqueID == audioID }
        busy = true; hasFrames = false; measured = ""; status = "캡처 시작 중…"
        generation += 1
        let request = generation
        Task { [self] in
            let videoAllowed = await authorize(.video)
            guard request == generation else { return }
            guard videoAllowed else { busy = false; status = "카메라 접근이 꺼져 있습니다. 시스템 설정 → 개인정보 보호 및 보안 → 카메라에서 허용하세요."; return }
            if selectedAudio != nil {
                let audioAllowed = await authorize(.audio)
                guard request == generation else { return }
                guard audioAllowed else { busy = false; status = "오디오 입력을 사용하려면 마이크 접근을 허용하거나 오디오를 ‘없음’으로 선택하세요."; return }
            }
            engine.configure(video: device, mode: mode, audio: selectedAudio, volume: muted ? 0 : Float(volume)) { [weak self] result in
                guard let self, request == self.generation else { return }
                self.busy = false
                switch result {
                case .success: if self.renderer != nil { self.rendererError = nil }; self.running = true; self.lastFrame = Date(); self.status = "프레임 대기 중…"; self.refresh()
                case .failure(let error): self.running = false; self.hasFrames = false; self.status = error.localizedDescription
                }
            }
        }
    }
    private func authorize(_ type: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: type)
        default: return false
        }
    }
    func stop(message: String = "캡처가 중지됐습니다", restart: Bool = false) {
        generation += 1
        let request = generation
        running = false; hasFrames = false; measured = ""; busy = true; frameInfo = nil
        frameTap.clear()
        engine.stop { [weak self] in
            // Frames queued before the session stopped may have refilled the tap.
            self?.frameTap.clear()
            guard let self, self.generation == request else { return }
            self.busy = false; self.status = message
            if self.audios.contains(where: { $0.uniqueID == self.preferredAudio }) { self.audioID = self.preferredAudio }
            if restart { self.start() }
        }
    }
}
