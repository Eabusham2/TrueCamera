import XCTest
import CoreImage
import CoreVideo
@testable import TrueCamera

final class SceneIntelligenceTests: XCTestCase {
    private func buffer() throws -> CVPixelBuffer {
        var result:CVPixelBuffer?
        let status=CVPixelBufferCreate(kCFAllocatorDefault,256,256,kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey:true,kCVPixelBufferCGBitmapContextCompatibilityKey:true] as CFDictionary,&result)
        XCTAssertEqual(status,kCVReturnSuccess)
        let pixelBuffer=try XCTUnwrap(result)
        CVPixelBufferLockBaseAddress(pixelBuffer,[])
        let bytes=try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to:UInt8.self))
        let stride=CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<256 {
            for x in 0..<256 {
                let i=y*stride+x*4
                let checker=((x/32+y/32)%2)==0
                bytes[i]=checker ? 180 : 50
                bytes[i+1]=UInt8(40+(x*180/256))
                bytes[i+2]=UInt8(30+(y*200/256))
                bytes[i+3]=255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer,[])
        return pixelBuffer
    }
    private func data(_ buffer:CVPixelBuffer)->Data {
        CVPixelBufferLockBaseAddress(buffer,.readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer,.readOnly) }
        return Data(bytes:CVPixelBufferGetBaseAddress(buffer)!,
                    count:CVPixelBufferGetBytesPerRow(buffer)*CVPixelBufferGetHeight(buffer))
    }
    func testExecutesAppleNeuralModelsWithoutMutatingCameraPixels() throws {
        let pixels=try buffer(), original=data(pixels)
        let result=try SceneIntelligence().infer(pixelBuffer:pixels,timestamp:1)
        XCTAssertEqual(result.performedNeuralRequests,4)
        XCTAssertGreaterThan(result.classificationCount,0)
        XCTAssertFalse(result.evidence.classifications.isEmpty)
        XCTAssertTrue(result.evidence.classifications.allSatisfy { $0.confidence.isFinite })
        XCTAssertEqual(result.histogram.count,32)
        XCTAssertEqual(result.histogram.reduce(0,+),1,accuracy:0.000001)
        XCTAssertEqual(data(pixels),original,"Inference must never alter camera output pixels")
        // This fixture proves model execution and read-only behavior, not semantic accuracy.
    }
    func testHistogramMeasuresPixelsRatherThanInventingSceneBrightness() throws {
        let provider=try XCTUnwrap(CGDataProvider(data:Data([128,128,128,255]) as CFData))
        let cg=try XCTUnwrap(CGImage(width:1,height:1,bitsPerComponent:8,bitsPerPixel:32,
            bytesPerRow:4,space:CGColorSpaceCreateDeviceRGB(),
            bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),
            provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
        let result=try SceneIntelligence.photometry(cg)
        XCTAssertEqual(result.mean,128.0/255,accuracy:0.005)
        XCTAssertEqual(result.clipped,0)
        XCTAssertEqual(result.redGreen,1,accuracy:0.01)
        XCTAssertEqual(result.blueGreen,1,accuracy:0.01)
    }
    func testDisabledAIProducesNoDecision() throws {
        let ai=SceneIntelligence()
        let unwanted=expectation(description:"No disabled AI callbacks")
        unwanted.isInverted=true
        ai.onDecision={ _ in unwanted.fulfill() }
        var settings=CameraSettings(); settings.aiEnabled=false
        ai.analyze(pixelBuffer:try buffer(),timestamp:1,settings:settings,telemetry:CameraTelemetry())
        wait(for:[unwanted],timeout:0.1)
    }
    func testInFlightAnalysisCannotPublishAfterInvalidation() throws {
        let ai=SceneIntelligence(), pixels=try buffer()
        let unwanted=expectation(description:"No obsolete decision")
        unwanted.isInverted=true
        ai.onDecision={ _ in unwanted.fulfill() }
        let settings=CameraSettings()
        ai.analyze(pixelBuffer:pixels,timestamp:1,settings:settings,telemetry:CameraTelemetry())
        ai.invalidate()
        wait(for:[unwanted],timeout:0.3)
    }
}
