import XCTest
import UIKit
import CoreImage
import CoreVideo
@testable import TrueCamera

final class LiveTextDetectorTests: XCTestCase {
    func testRecognizesUprightPortraitCameraBufferWithoutChangingPixels() throws {
        let size = CGSize(width: 768, height: 1024)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { canvas in
            UIColor.white.setFill()
            canvas.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 64, weight: .bold),
                .foregroundColor: UIColor.black
            ]
            ("TRUE CAMERA" as NSString).draw(at: CGPoint(x: 70, y: 160), withAttributes: attributes)
            ("2468 1357" as NSString).draw(at: CGPoint(x: 70, y: 360), withAttributes: attributes)
            ("FOCUS" as NSString).draw(at: CGPoint(x: 70, y: 560), withAttributes: attributes)
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height),
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true,
             kCVPixelBufferCGBitmapContextCompatibilityKey: true,
             kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        let pixels = try XCTUnwrap(pixelBuffer)
        CIContext(options: [.useSoftwareRenderer: true]).render(CIImage(cgImage: cgImage),
            to: pixels, bounds: CGRect(origin: .zero, size: size), colorSpace: CGColorSpaceCreateDeviceRGB())
        let original = bytes(pixels)

        // Exercise the production Vision OCR entry point with the already-upright
        // portrait buffer contract used by CaptureEngine, not mocked observations.
        let text = LiveTextDetector().recognize(pixels).joined(separator: " ").uppercased()
        XCTAssertTrue(text.contains("TRUE CAMERA"), text)
        XCTAssertTrue(text.contains("2468 1357"), text)
        XCTAssertTrue(text.contains("FOCUS"), text)
        XCTAssertEqual(bytes(pixels), original, "Live Text analysis must never alter camera pixels")
    }

    private func bytes(_ buffer: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        return Data(bytes: CVPixelBufferGetBaseAddress(buffer)!,
                    count: CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
    }
}
