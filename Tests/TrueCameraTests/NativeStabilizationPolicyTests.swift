import XCTest
import AVFoundation
@testable import TrueCamera

final class NativeStabilizationPolicyTests: XCTestCase {
    func testActionAssistOffCannotFallBackToAnOrdinaryNativeMode() {
        var settings = CameraSettings()
        settings.mode = .video
        settings.actionStabilization = true
        settings.horizonLock = false
        settings.zoomLock = false
        for choice: StabilizationChoice in [.off, .standard, .cinematic] {
            settings.stabilization = choice
            settings.actionNativeAssist = false
            XCTAssertEqual(NativeMovieController.preferredStabilization(settings, supports: { _ in true }), .off)
            settings.actionNativeAssist = true
            XCTAssertEqual(NativeMovieController.preferredStabilization(settings, supports: { $0 == .standard }), .standard)
        }
    }

    func testFramingLocksAndPhotoModeOverrideNativeActionAssist() {
        var settings = CameraSettings()
        settings.mode = .video
        settings.actionStabilization = true
        settings.actionNativeAssist = true
        for (horizon, zoom) in [(true, false), (false, true), (true, true)] {
            settings.horizonLock = horizon
            settings.zoomLock = zoom
            XCTAssertEqual(NativeMovieController.preferredStabilization(settings, supports: { _ in true }), .off)
        }
        settings.horizonLock = false
        settings.zoomLock = false
        settings.mode = .photo
        XCTAssertEqual(NativeMovieController.preferredStabilization(settings, supports: { _ in true }), .off)
    }

    func testActionAssistChoosesOnlySupportedModes() {
        var settings = CameraSettings()
        settings.mode = .video
        settings.actionStabilization = true
        settings.actionNativeAssist = true
        settings.horizonLock = false
        settings.zoomLock = false
        XCTAssertEqual(NativeMovieController.preferredStabilization(settings, supports: { _ in false }), .off)
        XCTAssertEqual(NativeMovieController.preferredStabilization(settings, supports: { $0 == .cinematic || $0 == .standard }), .cinematic)
        if #available(iOS 18.0, *) {
            XCTAssertEqual(NativeMovieController.preferredStabilization(settings, supports: {
                $0 == .cinematicExtendedEnhanced || $0 == .cinematicExtended
            }), .cinematicExtendedEnhanced)
        }
        if #available(iOS 26.0, *) {
            XCTAssertEqual(NativeMovieController.preferredStabilization(settings, supports: {
                $0 == .lowLatency || $0 == .cinematicExtended
            }), .lowLatency)
        }
    }

    func testInactiveActionAssistDoesNotOverrideTheSelectedNativeMode() {
        var settings = CameraSettings()
        settings.mode = .video
        settings.actionStabilization = false
        settings.stabilization = .cinematic
        settings.horizonLock = false
        settings.zoomLock = false
        for assist in [false, true] {
            settings.actionNativeAssist = assist
            XCTAssertEqual(NativeMovieController.preferredStabilization(settings, supports: { $0 == .cinematic }), .cinematic)
            XCTAssertEqual(NativeMovieController.preferredStabilization(settings, supports: { $0 == .standard }), .off)
        }
    }
}
