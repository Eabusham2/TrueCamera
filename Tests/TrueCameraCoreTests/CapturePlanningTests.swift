import XCTest
@testable import TrueCameraCore

final class CapturePlanningTests: XCTestCase {
    func testDualProRAWIsTwoDistinctRequestsAndNeverProRAWLive() throws {
        let steps = try PhotoCapturePlanner.steps(dual: true, raw: false, preferProRAW: true,
            live: false, exactExposure: false, supportsBayerRAW: true, supportsProRAW: true, supportsLive: true)
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps[0].rawKind, .appleProRAW)
        XCTAssertFalse(steps[0].live)
        XCTAssertTrue(steps[1].live)
        XCTAssertEqual(steps[1].rawKind, .none)
        XCTAssertTrue(steps.allSatisfy { $0.maximumQuality && $0.maximumResolution })
    }
    func testMissingRawOrLiveDoesNotSilentlyDowngradePair() {
        XCTAssertThrowsError(try PhotoCapturePlanner.steps(dual: true, raw: true, preferProRAW: true,
            live: true, exactExposure: false, supportsBayerRAW: true, supportsProRAW: false, supportsLive: true)) {
            XCTAssertEqual($0 as? PhotoPlanError, .proRAWUnavailable)
        }
        XCTAssertThrowsError(try PhotoCapturePlanner.steps(dual: true, raw: true, preferProRAW: false,
            live: true, exactExposure: false, supportsBayerRAW: true, supportsProRAW: true, supportsLive: false)) {
            XCTAssertEqual($0 as? PhotoPlanError, .liveUnavailable)
        }
    }
    func testExactExposureRejectsMaximumApplePair() {
        XCTAssertThrowsError(try PhotoCapturePlanner.steps(dual: true, raw: true, preferProRAW: true,
            live: true, exactExposure: true, supportsBayerRAW: true, supportsProRAW: true, supportsLive: true)) {
            XCTAssertEqual($0 as? PhotoPlanError, .exactMaximumConflict)
        }
    }
    func testSingleBayerLiveIsSupportedButProRAWLiveRejected() throws {
        let steps = try PhotoCapturePlanner.steps(dual: false, raw: true, preferProRAW: false,
            live: true, exactExposure: true, supportsBayerRAW: true, supportsProRAW: true, supportsLive: true)
        XCTAssertEqual(steps.count, 1)
        XCTAssertTrue(steps[0].live)
        XCTAssertTrue(steps[0].exactExposure)
        XCTAssertThrowsError(try PhotoCapturePlanner.steps(dual: false, raw: true, preferProRAW: true,
            live: true, exactExposure: false, supportsBayerRAW: true, supportsProRAW: true, supportsLive: true)) {
            XCTAssertEqual($0 as? PhotoPlanError, .proRAWWithLive)
        }
    }
    func testPhotoShutterUsesSensorLimitAndVideoUsesFrameLimit() {
        XCTAssertEqual(PhotoCapturePlanner.boundedShutter(0.5, minimum: 0.0001, maximum: 1, videoFPS: nil), 0.5)
        XCTAssertEqual(PhotoCapturePlanner.boundedShutter(0.5, minimum: 0.0001, maximum: 1, videoFPS: 30)!, 1.0/30, accuracy: 1e-10)
        XCTAssertNil(PhotoCapturePlanner.boundedShutter(.nan, minimum: 0.0001, maximum: 1, videoFPS: nil))
        XCTAssertNil(PhotoCapturePlanner.boundedShutter(0.01, minimum: 0.0001, maximum: 1, videoFPS: 0))
    }
    func testBayerRAWRequiresExactNativeZoomAndNoConnectionCrop() throws {
        XCTAssertNoThrow(try PhotoCapturePlanner.validateRAWZoom(rawKind: .bayer,
            deviceZoomFactor: 1, connectionScaleAndCropFactor: 1, isZoomRamping: false))
        for factor in [Double(1).nextUp, 2, 0.5, .nan, .infinity] {
            XCTAssertThrowsError(try PhotoCapturePlanner.validateRAWZoom(rawKind: .bayer,
                deviceZoomFactor: factor, connectionScaleAndCropFactor: 1, isZoomRamping: false)) {
                XCTAssertEqual($0 as? PhotoPlanError, .bayerRAWZoom)
            }
            XCTAssertThrowsError(try PhotoCapturePlanner.validateRAWZoom(rawKind: .bayer,
                deviceZoomFactor: 1, connectionScaleAndCropFactor: factor, isZoomRamping: false)) {
                XCTAssertEqual($0 as? PhotoPlanError, .bayerRAWZoom)
            }
        }
        XCTAssertThrowsError(try PhotoCapturePlanner.validateRAWZoom(rawKind: .bayer,
            deviceZoomFactor: 1, connectionScaleAndCropFactor: 1, isZoomRamping: true)) {
            XCTAssertEqual($0 as? PhotoPlanError, .bayerRAWZoom)
        }
    }
    func testBayerZoomRestrictionDoesNotApplyToProRAWOrProcessedPhotos() {
        for kind in [RAWCaptureKind.appleProRAW, .none] {
            XCTAssertNoThrow(try PhotoCapturePlanner.validateRAWZoom(rawKind: kind,
                deviceZoomFactor: 3, connectionScaleAndCropFactor: 1.5, isZoomRamping: true))
        }
    }
    func testSingleCaptureHonorsPriorityWhileExactExposureAndDualKeepTheirContracts() throws {
        for raw in [false, true] {
            let single = try PhotoCapturePlanner.steps(dual: false, raw: raw, preferProRAW: true,
                live: false, exactExposure: false, supportsBayerRAW: true, supportsProRAW: true,
                supportsLive: true)[0]
            XCTAssertFalse(single.maximumQuality)
            for priority in PhotoCapturePriority.allCases {
                XCTAssertEqual(PhotoCapturePlanner.effectivePriority(for: single, requested: priority), priority)
            }
        }
        let exact = try PhotoCapturePlanner.steps(dual: false, raw: false, preferProRAW: true,
            live: false, exactExposure: true, supportsBayerRAW: true, supportsProRAW: true,
            supportsLive: true)[0]
        XCTAssertEqual(PhotoCapturePlanner.effectivePriority(for: exact, requested: .quality), .speed)
        for proRAW in [false, true] {
            let pair = try PhotoCapturePlanner.steps(dual: true, raw: true, preferProRAW: proRAW,
                live: true, exactExposure: false, supportsBayerRAW: true, supportsProRAW: true,
                supportsLive: true)
            XCTAssertEqual(PhotoCapturePlanner.effectivePriority(for: pair[0], requested: .speed), proRAW ? .quality : .speed)
            XCTAssertEqual(PhotoCapturePlanner.effectivePriority(for: pair[1], requested: .speed), .quality)
            XCTAssertTrue(pair.allSatisfy { $0.maximumResolution })
        }
    }
    func testResolutionPolicyMatchesNativePriorityFamiliesIncludingActual48MPDimensions() {
        let twelve = 4032.0 * 3024 / 1_000_000
        let fortyEight = 8064.0 * 6048 / 1_000_000
        let reported = [twelve, 18, 24, fortyEight]
        XCTAssertEqual(reported.filter { PhotoCapturePlanner.supportsResolution(megapixels: $0, priority: .speed) }, [twelve])
        XCTAssertEqual(reported.filter { PhotoCapturePlanner.supportsResolution(megapixels: $0, priority: .balanced) }, [twelve, fortyEight])
        XCTAssertEqual(reported.filter { PhotoCapturePlanner.supportsResolution(megapixels: $0, priority: .quality) }, reported)
        for priority in PhotoCapturePriority.allCases {
            for invalid in [Double.nan, .infinity, 0, -12] {
                XCTAssertFalse(PhotoCapturePlanner.supportsResolution(megapixels: invalid, priority: priority))
            }
        }
        XCTAssertTrue(PhotoCapturePlanner.supportsResolution(megapixels: 49, priority: .balanced))
    }
}
