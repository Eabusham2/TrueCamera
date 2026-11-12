import XCTest
@testable import TrueCamera

final class ExposureControlTests: XCTestCase {
    func testPhotoShutterRemainsEditableAfterVideoShutterAngle() {
        var settings = CameraSettings()
        settings.mode = .video
        settings.manualExposure = true
        settings.shutterAngleMode = true
        settings.shutterAngle = 180
        settings.fps = 60
        settings.shutterDenominator = 125
        XCTAssertEqual(settings.manualExposureDuration, 1 / 120, accuracy: 0.000001)

        let video = settings
        settings.mode = .photo
        settings.normalize(changedFrom: video)
        XCTAssertTrue(settings.shutterAngleMode, "Keep the saved video preference without applying it to still photos")
        XCTAssertEqual(settings.manualExposureDuration, 1 / 125, accuracy: 0.000001)
        settings.shutterDenominator = 10
        XCTAssertEqual(settings.manualExposureDuration, 0.1, accuracy: 0.000001,
                       "The duration shown by the Photo slider must drive manual exposure, including AI aperture changes")

        let photo = settings
        settings.mode = .video
        settings.normalize(changedFrom: photo)
        XCTAssertEqual(settings.manualExposureDuration, 1 / 120, accuracy: 0.000001)
    }

    func testSlowMotionAngleUsesCaptureRateInsteadOfPlaybackRate() {
        var settings = CameraSettings()
        settings.mode = .slowMotion
        settings.shutterAngleMode = true
        settings.shutterAngle = 180
        settings.fps = 30
        settings.slowMotionFPS = 240
        XCTAssertEqual(settings.manualExposureDuration, 1 / 480, accuracy: 0.000001)
    }

    func testVideoDirectShutterDurationDoesNotUseStoredAngle() {
        var settings = CameraSettings()
        settings.mode = .video
        settings.shutterAngleMode = false
        settings.shutterAngle = 90
        settings.fps = 30
        settings.shutterDenominator = 250
        XCTAssertEqual(settings.manualExposureDuration, 1 / 250, accuracy: 0.000001)
    }
}
