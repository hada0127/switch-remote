import AVFoundation
import CoreMedia
import OSLog

struct VideoMode: Identifiable {
    let id: Int
    let formatIndex: Int
    let width: Int32
    let height: Int32
    let duration: CMTime
    var fps: Double { 1 / CMTimeGetSeconds(duration) }
    var preferenceKey: String { "\(width)x\(height)@\(Int((fps * 1000).rounded()))" }
    static func preferredDuration(minimum: CMTime, maximum: CMTime) -> CMTime {
        let target = CMTime(value: 1, timescale: 60)
        if CMTimeCompare(target, minimum) < 0 { return minimum }
        if CMTimeCompare(target, maximum) > 0 { return maximum }
        return target
    }
    var label: String {
        let rate = abs(fps - fps.rounded()) < 0.001 ? String(Int(fps.rounded())) : String(format: "%.2f", fps)
        return "\(width) × \(height) · \(rate) fps"
    }
    static func preferred(in modes: [VideoMode]) -> VideoMode? {
        modes.filter { $0.width == 1920 && $0.height == 1080 }
            .min { abs($0.fps - 60) < abs($1.fps - 60) } ?? modes.first
    }
    static func unique(_ modes: [VideoMode]) -> [VideoMode] {
        modes.reduce(into: [VideoMode]()) { list, mode in
            if !list.contains(where: { $0.width == mode.width && $0.height == mode.height && abs($0.fps - mode.fps) < 0.001 }) { list.append(mode) }
        }.sorted { $0.rank > $1.rank }
    }
    var rank: Double { Double(width) * Double(height) * min(fps, 60) }
}

/// All session mutations run on queue; frame callbacks run on frameQueue.
final class CaptureEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "net.tarucy.capture.session", qos: .userInitiated)
    private let frameQueue = DispatchQueue(label: "net.tarucy.capture.frames", qos: .userInteractive)
    private var previewAudio: AVCaptureAudioPreviewOutput?
    private var frames = 0
    private var epoch = CFAbsoluteTimeGetCurrent()
    var onVideoFrame: ((CVPixelBuffer) -> Void)?
    var onFrames: ((Int32, Int32, Double) -> Void)?

    static func modes(for device: AVCaptureDevice) -> [VideoMode] {
        var candidates: [VideoMode] = []
        for (index, format) in device.formats.enumerated() {
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard d.width > 0, d.height > 0 else { continue }
            for range in format.videoSupportedFrameRateRanges {
                guard range.minFrameDuration.isNumeric, range.maxFrameDuration.isNumeric,
                      CMTimeGetSeconds(range.minFrameDuration) > 0,
                      CMTimeCompare(range.minFrameDuration, range.maxFrameDuration) <= 0 else { continue }
                let duration = VideoMode.preferredDuration(minimum: range.minFrameDuration, maximum: range.maxFrameDuration)
                candidates.append(VideoMode(id: candidates.count, formatIndex: index, width: d.width, height: d.height, duration: duration))
            }
        }
        return VideoMode.unique(candidates)
    }

    func configure(video: AVCaptureDevice, mode: VideoMode, audio: AVCaptureDevice?, volume: Float, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            self.session.stopRunning()
            self.session.beginConfiguration()
            self.session.inputs.forEach { self.session.removeInput($0) }
            self.session.outputs.forEach { self.session.removeOutput($0) }
            self.previewAudio = nil
            var configuring = true
            do {
                let input = try AVCaptureDeviceInput(device: video)
                guard self.session.canAddInput(input) else { throw CaptureFailure.message("선택한 영상 장치를 열 수 없습니다.") }
                self.session.addInput(input)
                guard video.formats.indices.contains(mode.formatIndex) else { throw CaptureFailure.message("영상 형식이 변경됐습니다. 장치를 다시 선택하세요.") }
                let data = AVCaptureVideoDataOutput()
                data.alwaysDiscardsLateVideoFrames = true
                if data.availableVideoPixelFormatTypes.contains(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
                    data.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
                }
                data.setSampleBufferDelegate(self, queue: self.frameQueue)
                guard self.session.canAddOutput(data) else { throw CaptureFailure.message("영상 미리보기를 시작할 수 없습니다.") }
                self.session.addOutput(data)
                if let audio {
                    if audio.uniqueID != video.uniqueID {
                        let audioInput = try AVCaptureDeviceInput(device: audio)
                        guard self.session.canAddInput(audioInput) else { throw CaptureFailure.message("선택한 오디오 장치를 열 수 없습니다.") }
                        self.session.addInput(audioInput)
                    }
                    let output = AVCaptureAudioPreviewOutput()
                    output.volume = volume
                    guard self.session.canAddOutput(output) else { throw CaptureFailure.message("오디오 재생을 시작할 수 없습니다.") }
                    self.session.addOutput(output)
                    self.previewAudio = output
                }
                self.session.commitConfiguration()
                configuring = false
                self.frameQueue.sync { self.frames = 0; self.epoch = CFAbsoluteTimeGetCurrent() }
                self.session.startRunning()
                try video.lockForConfiguration()
                video.activeFormat = video.formats[mode.formatIndex]
                let duration = mode.duration
                video.activeVideoMinFrameDuration = duration
                video.activeVideoMaxFrameDuration = duration
                video.unlockForConfiguration()
                let actual = CMVideoFormatDescriptionGetDimensions(video.activeFormat.formatDescription)
                Logger(subsystem: "net.tarucy.videogamefilter.native", category: "capture").info("Active format: \(actual.width)x\(actual.height), min \(CMTimeGetSeconds(video.activeVideoMinFrameDuration)), max \(CMTimeGetSeconds(video.activeVideoMaxFrameDuration))")
                guard self.session.isRunning else { throw CaptureFailure.message("캡처가 시작되지 않았습니다. QuickTime 등 다른 앱에서 장치 사용을 종료하고 다시 시도하세요.") }
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                if configuring { self.session.commitConfiguration() }
                self.session.stopRunning()
                self.session.beginConfiguration()
                self.session.inputs.forEach { self.session.removeInput($0) }
                self.session.outputs.forEach { self.session.removeOutput($0) }
                self.session.commitConfiguration()
                self.previewAudio = nil
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func stop(completion: @escaping () -> Void) {
        queue.async {
            self.session.stopRunning()
            self.session.beginConfiguration()
            self.session.inputs.forEach { self.session.removeInput($0) }
            self.session.outputs.forEach { self.session.removeOutput($0) }
            self.session.commitConfiguration()
            self.previewAudio = nil
            DispatchQueue.main.async(execute: completion)
        }
    }
    func volume(_ value: Float) { queue.async { self.previewAudio?.volume = value } }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) { onVideoFrame?(pixelBuffer) }
        frames += 1
        let now = CFAbsoluteTimeGetCurrent(), elapsed = now - epoch
        guard elapsed >= 0.5, let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        let rate = Double(frames) / elapsed
        frames = 0; epoch = now
        onFrames?(dimensions.width, dimensions.height, rate)
    }
}
enum CaptureFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
