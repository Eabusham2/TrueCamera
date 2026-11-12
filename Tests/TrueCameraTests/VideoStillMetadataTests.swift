import XCTest
import CoreImage
import CoreLocation
import CoreVideo
import ImageIO
@testable import TrueCamera

final class VideoStillMetadataTests: XCTestCase {
    private let captureDate = Date(timeIntervalSince1970: 1_700_000_000.375)

    private func image() -> CIImage {
        CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.6))
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48))
    }

    private func location() -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: 30.2672, longitude: -97.7431),
                   altitude: 155, horizontalAccuracy: 6, verticalAccuracy: 8, timestamp: captureDate)
    }

    private func read(_ data: Data) throws -> [String: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
    }

    func testVideoStillTimeGPSAndCustomMetadataRoundTripWithoutInventedSensorEXIF() throws {
        let renderer = try XCTUnwrap(ImageRenderer())
        var settings = CameraSettings()
        settings.customMetadataEnabled = true
        settings.includeLocationMetadata = true
        settings.metadataAuthor = "Video author"
        settings.metadataTitle = "Video frame"
        settings.metadataDescription = "Frame from recording"
        settings.manualExposure = true
        settings.iso = 800
        settings.shutterDenominator = 1000
        settings.aperture = 2.8
        for efficient in [false, true] {
            let encoded = try XCTUnwrap(CaptureMetadata.encodeProcessed(image(), renderer: renderer,
                efficient: efficient, settings: settings, captureDate: captureDate,
                location: location(), maximumQuality: true))
            XCTAssertEqual(encoded.1, efficient ? "heic" : "jpg")
            let properties = try read(encoded.0)
            XCTAssertEqual(properties[kCGImagePropertyPixelWidth as String] as? Int, 64)
            XCTAssertEqual(properties[kCGImagePropertyPixelHeight as String] as? Int, 48)
            let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary as String] as? [String: Any])
            XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal as String] as? String, "2023:11:14 22:13:20")
            XCTAssertEqual(exif[kCGImagePropertyExifOffsetTimeOriginal as String] as? String, "+00:00")
            XCTAssertEqual(exif[kCGImagePropertyExifSubsecTimeOriginal as String] as? String, "375")
            XCTAssertNil(exif[kCGImagePropertyExifISOSpeedRatings as String])
            XCTAssertNil(exif[kCGImagePropertyExifExposureTime as String])
            XCTAssertNil(exif[kCGImagePropertyExifFNumber as String])
            XCTAssertNil(exif[kCGImagePropertyExifFocalLength as String])
            let gps = try XCTUnwrap(properties[kCGImagePropertyGPSDictionary as String] as? [String: Any])
            XCTAssertEqual(try XCTUnwrap((gps[kCGImagePropertyGPSLatitude as String] as? NSNumber)?.doubleValue), 30.2672, accuracy: 0.00001)
            XCTAssertEqual(try XCTUnwrap((gps[kCGImagePropertyGPSLongitude as String] as? NSNumber)?.doubleValue), 97.7431, accuracy: 0.00001)
            XCTAssertEqual(gps[kCGImagePropertyGPSLongitudeRef as String] as? String, "W")
            let tiff = try XCTUnwrap(properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any])
            XCTAssertEqual(tiff[kCGImagePropertyTIFFArtist as String] as? String, settings.metadataAuthor)
            XCTAssertEqual(tiff[kCGImagePropertyTIFFDateTime as String] as? String, "2023:11:14 22:13:20")
            let iptc = try XCTUnwrap(properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any])
            XCTAssertEqual(iptc[kCGImagePropertyIPTCObjectName as String] as? String, settings.metadataTitle)
        }
    }

    func testLocationAndCustomMetadataOffKeepOnlyTruthfulFrameTime() throws {
        let renderer = try XCTUnwrap(ImageRenderer())
        var settings = CameraSettings()
        settings.includeLocationMetadata = false
        settings.customMetadataEnabled = false
        settings.metadataAuthor = "Must not appear"
        for efficient in [false, true] {
            let encoded = try XCTUnwrap(CaptureMetadata.encodeProcessed(image(), renderer: renderer,
                efficient: efficient, settings: settings, captureDate: captureDate,
                location: location(), maximumQuality: true))
            let properties = try read(encoded.0)
            XCTAssertNil(properties[kCGImagePropertyGPSDictionary as String])
            let tiff = try XCTUnwrap(properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any])
            XCTAssertNil(tiff[kCGImagePropertyTIFFArtist as String])
            let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary as String] as? [String: Any])
            XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal as String] as? String, "2023:11:14 22:13:20")
        }
    }

    func testFrameTimeUsesSourceTimestampAndRejectsStaleOrInvalidPreview() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let result = try XCTUnwrap(CaptureMetadata.frameCaptureDate(hostTime: 99.25, hostNow: 100, wallNow: now))
        XCTAssertEqual(result.timeIntervalSince1970, now.timeIntervalSince1970 - 0.75, accuracy: 0.000001)
        for invalid in [Double?.none, .some(.nan), .some(.infinity), .some(97.9), .some(100.1)] {
            XCTAssertNil(CaptureMetadata.frameCaptureDate(hostTime: invalid, hostNow: 100, wallNow: now))
        }
        XCTAssertNil(CaptureMetadata.frameCaptureDate(hostTime: 99, hostNow: .nan, wallNow: now))
    }

    func testFrameProcessorPublishesTimestampForBothPreviewAndRecording() throws {
        let renderer = try XCTUnwrap(ImageRenderer())
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferMetalCompatibilityKey as String: true,
             kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        renderer.render(image(), into: pixels)
        let processor = FrameProcessor(motion: MotionService(), renderer: renderer)
        var settings = CameraSettings()
        settings.mode = .video
        settings.horizonLock = false
        settings.zoomLock = false
        settings.actionStabilization = false
        processor.configure(settings, front: false)
        XCTAssertEqual(try processor.process(buffer: pixels, hostTime: 100).hostTime, 100)
        XCTAssertEqual(processor.preview.snapshot()?.hostTime, 100)
        processor.beginRecording()
        XCTAssertEqual(try processor.process(buffer: pixels, hostTime: 100.1).hostTime, 100.1)
        XCTAssertEqual(processor.preview.snapshot()?.hostTime, 100.1)
    }
}
