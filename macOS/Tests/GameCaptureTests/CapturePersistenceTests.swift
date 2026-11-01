import XCTest
import CoreMedia
@testable import GameCapture

@MainActor final class CapturePersistenceTests: XCTestCase {
    func testSavedSettingsSurviveLaunchAndUnavailableChoicesRemainSaved() {
        let suite = "capture-persistence-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("missing-video", forKey: "capture.videoID")
        defaults.set("missing-audio", forKey: "capture.audioID")
        defaults.set("2560x1440@59940", forKey: "capture.mode")
        defaults.set(0.35, forKey: "capture.volume")
        defaults.set(true, forKey: "capture.muted")
        let model = CaptureModel(defaults: defaults)
        XCTAssertEqual(model.volume, 0.35)
        XCTAssertTrue(model.muted)
        XCTAssertEqual(defaults.string(forKey: "capture.videoID"), "missing-video")
        XCTAssertEqual(defaults.string(forKey: "capture.audioID"), "missing-audio")
        XCTAssertEqual(defaults.string(forKey: "capture.mode"), "2560x1440@59940")
        model.volume = 0.8; model.muted = false
        XCTAssertEqual(defaults.double(forKey: "capture.volume"), 0.8)
        XCTAssertFalse(defaults.bool(forKey: "capture.muted"))
    }

    func testModePreferenceDoesNotDependOnEnumerationIndex() {
        let mode = VideoMode(id: 83, formatIndex: 17, width: 1920, height: 1080,
                             duration: CMTime(value: 1001, timescale: 60000))
        XCTAssertEqual(mode.preferenceKey, "1920x1080@59940")
    }
    func testPreferredAudioWaitsUntilCaptureHasStopped() {
        XCTAssertFalse(CaptureModel.shouldRestoreAudio(running: true, busy: false, current: "fallback", preferred: "saved", available: true))
        XCTAssertFalse(CaptureModel.shouldRestoreAudio(running: false, busy: true, current: "fallback", preferred: "saved", available: true))
        XCTAssertTrue(CaptureModel.shouldRestoreAudio(running: false, busy: false, current: "fallback", preferred: "saved", available: true))
        XCTAssertFalse(CaptureModel.shouldRestoreAudio(running: false, busy: false, current: "fallback", preferred: "saved", available: false))
    }
}
