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
}
