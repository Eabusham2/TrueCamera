import XCTest
import AVFoundation
@testable import TrueCamera

final class PhotoPreservationTests: XCTestCase {
    private func engine() throws -> CaptureEngine {
        CaptureEngine(renderer: try XCTUnwrap(ImageRenderer()))
    }

    private func packet(data: Data?, raw: Data?, live: URL? = nil, warning: String? = nil) throws -> PhotoPacket {
        let step = try PhotoCapturePlanner.steps(dual: true, raw: true, preferProRAW: true,
            live: true, exactExposure: false, supportsBayerRAW: true, supportsProRAW: true,
            supportsLive: true)[raw == nil ? 1 : 0]
        return PhotoPacket(data: data, rawData: raw, liveMovie: live,
            timestamp: .zero, settings: CameraSettings(), step: step,
            processedFileExtension: "heic", dimensions: CMVideoDimensions(width: 4032, height: 3024),
            rawDimensions: CMVideoDimensions(width: 8064, height: 6048),
            captureDate: Date(timeIntervalSince1970: 1_700_000_000), pairID: UUID(),
            hasDepthData: false, hasPortraitEffectsMatte: false, hasCalibrationData: false,
            warning: warning)
    }

    private func cleanup(_ result: CaptureEngine.SavedPhotoResources) {
        for draft in result.drafts {
            for url in [draft.url, draft.raw, draft.liveMovie].compactMap({ $0 }) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    func testRAWOriginalSurvivesProcessedCompanionFailureByteForByte() throws {
        let raw = Data([0x49, 0x49, 0x2A, 0x00, 0x01, 0xFE, 0xA5])
        let input = try packet(data: nil, raw: raw, warning: "Processed delivery interrupted")
        let saved = try engine().savePhoto(input)
        defer { cleanup(saved) }
        XCTAssertTrue(saved.rawSaved)
        XCTAssertEqual(saved.drafts.count, 1)
        let draft = try XCTUnwrap(saved.drafts.first)
        XCTAssertEqual(draft.url.pathExtension, "dng")
        XCTAssertEqual(try Data(contentsOf: draft.url), raw)
        XCTAssertNil(draft.raw)
        XCTAssertNil(draft.liveMovie)
        XCTAssertEqual(draft.created, input.captureDate)
        XCTAssertEqual(draft.pairID, input.pairID)
        XCTAssertNotNil(saved.warning)
    }

    func testFailedLiveMotionPreservesStillWithoutClaimingLivePhoto() throws {
        let encoded = Data([0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63])
        let saved = try engine().savePhoto(packet(data: encoded, raw: nil, warning: "Live motion interrupted"))
        defer { cleanup(saved) }
        let draft = try XCTUnwrap(saved.drafts.first)
        XCTAssertEqual(try Data(contentsOf: draft.url), encoded)
        XCTAssertFalse(saved.rawSaved)
        XCTAssertNil(draft.liveMovie)
        XCTAssertFalse(draft.isVideo)
        XCTAssertTrue(draft.summary.contains("Partial original capture"))
        XCTAssertNotNil(saved.warning)
    }

    func testBothNativePhotoContainersAreWrittenWithoutReencoding() throws {
        let raw = Data([0x49, 0x49, 0x2A, 0x00, 0xFF, 0x31])
        let encoded = Data([0x68, 0x65, 0x69, 0x63, 0xAE, 0x72])
        let saved = try engine().savePhoto(packet(data: encoded, raw: raw))
        defer { cleanup(saved) }
        let draft = try XCTUnwrap(saved.drafts.first)
        XCTAssertEqual(try Data(contentsOf: draft.url), encoded)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(draft.raw)), raw)
        XCTAssertTrue(saved.rawSaved)
        XCTAssertNil(saved.warning)
    }
}
