import XCTest
import CoreImage
@testable import TrueCamera

final class PreviewAnalysisTests: XCTestCase {
    private func pixels(width: Int = 8, height: Int = 8, value: (Int,Int) -> UInt8) -> [UInt8] {
        var result = [UInt8]()
        for y in 0..<height {
            for x in 0..<width {
                let v = value(x,y)
                result.append(contentsOf:[v,v,v,255])
            }
        }
        return result
    }

    func testHistogramAndHighlightFractionComeFromPreviewValues() throws {
        let input = pixels { x,_ in x < 4 ? 0 : 255 }
        let result = try XCTUnwrap(PreviewAssistAnalyzer.analyzeRGBA(input,width:8,height:8,zebras:false,focusPeaking:false))
        XCTAssertEqual(result.histogram.count,64)
        XCTAssertEqual(result.histogram.reduce(0,+),1,accuracy:1e-12)
        XCTAssertEqual(result.histogram[0],0.5,accuracy:1e-12)
        XCTAssertEqual(result.histogram[63],0.5,accuracy:1e-12)
        XCTAssertEqual(result.highlightFraction,0.5,accuracy:1e-12)
        XCTAssertNil(result.overlayRGBA)
    }

    func testZebraMaskMarksOnlyHighlightedPartOfImage() throws {
        let input = pixels { x,_ in x < 4 ? 128 : 255 }
        let result = try XCTUnwrap(PreviewAssistAnalyzer.analyzeRGBA(input,width:8,height:8,zebras:true,focusPeaking:false))
        let mask = try XCTUnwrap(result.overlayRGBA)
        var marked = 0
        for y in 0..<8 {
            for x in 0..<8 {
                let alpha = mask[(y*8+x)*4+3]
                if x < 4 { XCTAssertEqual(alpha,0) }
                if alpha > 0 { marked += 1 }
            }
        }
        XCTAssertGreaterThan(marked,0)
        XCTAssertLessThan(marked,32,"Zebras should alternate visible and transparent stripes.")
    }

    func testPeakingMarksActualEdgesWithoutMarkingFlatRegions() throws {
        let edge = pixels { x,_ in x < 4 ? 32 : 180 }
        let result = try XCTUnwrap(PreviewAssistAnalyzer.analyzeRGBA(edge,width:8,height:8,zebras:false,focusPeaking:true))
        let mask = try XCTUnwrap(result.overlayRGBA)
        XCTAssertGreaterThan(mask[(3*8+3)*4+3],0)
        XCTAssertGreaterThan(mask[(3*8+4)*4+3],0)
        XCTAssertEqual(mask[(3*8+1)*4+3],0)
        XCTAssertEqual(mask[(3*8+6)*4+3],0)
        let flat = try XCTUnwrap(PreviewAssistAnalyzer.analyzeRGBA(pixels { _,_ in 128 },width:8,height:8,zebras:false,focusPeaking:true))
        XCTAssertTrue(try XCTUnwrap(flat.overlayRGBA).allSatisfy { $0 == 0 })
    }

    func testPreviewAnalysisRejectsUnboundedOrMalformedRaster() {
        XCTAssertNil(PreviewAssistAnalyzer.analyzeRGBA([],width:0,height:0,zebras:true,focusPeaking:true))
        XCTAssertNil(PreviewAssistAnalyzer.analyzeRGBA([0],width:8,height:8,zebras:true,focusPeaking:true))
        XCTAssertNil(PreviewAssistAnalyzer.analyzeRGBA([],width:257,height:1,zebras:true,focusPeaking:true))
    }

    func testCoreImageMaskKeepsSameImageCoordinates() throws {
        let renderer = try XCTUnwrap(ImageRenderer())
        let bounds = CGRect(x:0,y:0,width:8,height:8)
        let source = CIImage(color:.white).cropped(to:CGRect(x:4,y:4,width:4,height:4))
            .composited(over:CIImage(color:CIColor(red:0.25,green:0.25,blue:0.25)).cropped(to:bounds))
            .cropped(to:bounds)
        let result = try XCTUnwrap(PreviewAssistAnalyzer.analyze(source,renderer:renderer,zebras:true,focusPeaking:false))
        let mask = CIImage(cgImage:try XCTUnwrap(result.overlay))
        func alpha(x: Int, y: Int) -> UInt8 {
            var rgba = [UInt8](repeating:0,count:4)
            rgba.withUnsafeMutableBytes { bytes in
                renderer.context.render(mask,toBitmap:bytes.baseAddress!,rowBytes:4,
                    bounds:CGRect(x:CGFloat(x),y:CGFloat(y),width:1,height:1),format:.RGBA8,colorSpace:renderer.colorSpace)
            }
            return rgba[3]
        }
        XCTAssertEqual(result.sourceSize,CGSize(width:8,height:8))
        XCTAssertGreaterThan(alpha(x:6,y:4),0)
        XCTAssertEqual(alpha(x:1,y:1),0)
        XCTAssertEqual(alpha(x:6,y:1),0)
    }
}
