import SwiftUI
import Combine
import CoreImage
import Foundation

/// Display aids only. This file never returns an image to CaptureEngine,
/// PhotoCapture or MovieRecorder and cannot alter a saved resource.
struct PreviewAssistRaster {
    let histogram: [Double]
    let highlightFraction: Double
    let overlayRGBA: [UInt8]?
}

enum PreviewAssistAnalyzer {
    static let maximumDimension = 256
    static let highlightThreshold: UInt8 = 250

    /// The histogram measures display-referred preview luma. Highlight stripes
    /// indicate any RGB preview channel at or above 250/255. They are not a
    /// measurement of the RAW sensor's remaining dynamic range.
    static func analyzeRGBA(_ pixels: [UInt8], width: Int, height: Int,
                            zebras: Bool, focusPeaking: Bool) -> PreviewAssistRaster? {
        guard width > 0, height > 0, width <= maximumDimension,
              height <= maximumDimension, pixels.count == width * height * 4 else { return nil }
        let count = width * height
        var luminance = [Float](repeating:0,count:count)
        var histogram = [Double](repeating:0,count:64)
        var overlay = (zebras || focusPeaking) ? [UInt8](repeating:0,count:count*4) : nil
        var highlights = 0, valid = 0
        for index in 0..<count {
            let offset = index * 4
            guard pixels[offset+3] > 0 else { continue }
            // RGB values are from the sRGB viewfinder rendering, not sensor RAW.
            let value = 0.2126 * Float(pixels[offset]) + 0.7152 * Float(pixels[offset+1]) + 0.0722 * Float(pixels[offset+2])
            luminance[index] = value
            histogram[min(63,max(0,Int(value)/4))] += 1
            valid += 1
            let highlighted = max(pixels[offset],max(pixels[offset+1],pixels[offset+2])) >= highlightThreshold
            if highlighted { highlights += 1 }
            if zebras && highlighted && ((index % width + index / width) % 8 < 4) {
                // Premultiplied RGBA, deliberately translucent over the preview.
                overlay?[offset] = 170; overlay?[offset+1] = 145
                overlay?[offset+2] = 20; overlay?[offset+3] = 180
            }
        }
        if focusPeaking && width > 2 && height > 2 {
            for y in 1..<(height-1) {
                for x in 1..<(width-1) {
                    let i = y * width + x
                    guard pixels[i*4+3] > 0 else { continue }
                    let a = luminance[i-width-1], b = luminance[i-width], c = luminance[i-width+1]
                    let d = luminance[i-1], f = luminance[i+1]
                    let g = luminance[i+width-1], h = luminance[i+width], j = luminance[i+width+1]
                    let gx = -a - 2*d - g + c + 2*f + j
                    let gy = -a - 2*b - c + g + 2*h + j
                    let magnitude = sqrt(gx*gx + gy*gy)
                    // A Sobel edge/contrast aid, not an assertion of subject focus.
                    // Requiring local contrast avoids marking flat image noise.
                    let minimum = min(min(a,min(b,c)),min(min(d,min(luminance[i],f)),min(g,min(h,j))))
                    let maximum = max(max(a,max(b,c)),max(max(d,max(luminance[i],f)),max(g,max(h,j))))
                    let contrast = maximum - minimum
                    if magnitude >= 160 && contrast >= 30 {
                        let offset = i * 4
                        overlay?[offset] = 16; overlay?[offset+1] = 200
                        overlay?[offset+2] = 70; overlay?[offset+3] = 210
                    }
                }
            }
        }
        let divisor = Double(max(1,valid))
        return PreviewAssistRaster(histogram:histogram.map { $0/divisor },
            highlightFraction:Double(highlights)/divisor,overlayRGBA:overlay)
    }

    static func analyze(_ source: CIImage, renderer: ImageRenderer,
                        zebras: Bool, focusPeaking: Bool) -> PreviewAssistSnapshot? {
        let extent = source.extent
        guard !extent.isInfinite, !extent.isNull, extent.width.isFinite,
              extent.height.isFinite, extent.width > 0, extent.height > 0 else { return nil }
        let sourceWidth = Double(extent.width), sourceHeight = Double(extent.height)
        let scale = min(1,Double(maximumDimension)/max(sourceWidth,sourceHeight))
        let width = max(1,Int((sourceWidth*scale).rounded(.down)))
        let height = max(1,Int((sourceHeight*scale).rounded(.down)))
        let bounds = CGRect(x:0,y:0,width:CGFloat(width),height:CGFloat(height))
        let small = source.transformed(by:CGAffineTransform(translationX:-extent.minX,y:-extent.minY))
            .transformed(by:CGAffineTransform(scaleX:CGFloat(width)/extent.width,y:CGFloat(height)/extent.height))
            .cropped(to:bounds)
        var pixels = [UInt8](repeating:0,count:width*height*4)
        pixels.withUnsafeMutableBytes { bytes in
            renderer.context.render(small,toBitmap:bytes.baseAddress!,rowBytes:width*4,
                bounds:bounds,format:.RGBA8,colorSpace:renderer.colorSpace)
        }
        guard let analysis = analyzeRGBA(pixels,width:width,height:height,zebras:zebras,focusPeaking:focusPeaking) else { return nil }
        let overlay: CGImage?
        if let bytes = analysis.overlayRGBA {
            // Using the inverse bitmap operation keeps mask rows aligned with the
            // Core Image source even though its coordinates have a lower-left origin.
            let mask = CIImage(bitmapData:Data(bytes),bytesPerRow:width*4,
                size:CGSize(width:CGFloat(width),height:CGFloat(height)),format:.RGBA8,colorSpace:renderer.colorSpace)
            overlay = renderer.context.createCGImage(mask,from:bounds,format:.RGBA8,colorSpace:renderer.colorSpace)
        } else { overlay = nil }
        return PreviewAssistSnapshot(sourceSize:extent.size,histogram:analysis.histogram,
            highlightFraction:analysis.highlightFraction,overlay:overlay)
    }
}

struct PreviewAssistSnapshot {
    let sourceSize: CGSize
    let histogram: [Double]
    let highlightFraction: Double
    let overlay: CGImage?
}

@MainActor final class PreviewAssistModel: ObservableObject {
    @Published private(set) var snapshot: PreviewAssistSnapshot?
    private let queue = DispatchQueue(label:"camera.preview-assists",qos:.utility)
    private var analyzing = false
    private var generation = 0
    private var lastRequest: TimeInterval = -.infinity

    func request(feed: PreviewFeed, renderer: ImageRenderer,
                 histogram: Bool, zebras: Bool, focusPeaking: Bool) {
        guard histogram || zebras || focusPeaking else { invalidate(); return }
        let now = ProcessInfo.processInfo.systemUptime
        guard !analyzing, now-lastRequest >= 0.25, let frame = feed.snapshot() else { return }
        analyzing = true; lastRequest = now
        let ticket = generation
        // At most one retained analysis frame and one pending result. Slow
        // analysis drops requests rather than stacking work behind capture.
        queue.async { [weak self] in
            let result = autoreleasepool {
                PreviewAssistAnalyzer.analyze(frame.image,renderer:renderer,zebras:zebras,focusPeaking:focusPeaking)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.analyzing = false
                guard self.generation == ticket else { return }
                self.snapshot = result
            }
        }
    }

    func invalidate() { generation &+= 1; snapshot = nil }
}

/// Place over the same full bounds as MetalPreview. Mask geometry uses exactly
/// its aspect-fit rectangle; transparent letterbox areas never get marked.
@MainActor struct CameraAssistOverlay: View {
    let feed: PreviewFeed
    let renderer: ImageRenderer
    let histogram: Bool
    let zebras: Bool
    let focusPeaking: Bool
    @StateObject private var model = PreviewAssistModel()
    private let clock = Timer.publish(every:0.25,on:.main,in:.common).autoconnect()

    var body: some View {
        GeometryReader { geometry in
            if let snapshot = model.snapshot {
                let rect = PreviewLayout.aspectFit(image:snapshot.sourceSize,in:geometry.size)
                if (zebras || focusPeaking), let overlay = snapshot.overlay {
                    Image(decorative:overlay,scale:1,orientation:.up)
                        .resizable().interpolation(.none)
                        .frame(width:rect.width,height:rect.height)
                        .position(x:rect.midX,y:rect.midY)
                }
                if histogram {
                    histogramView(snapshot)
                        .frame(width:120,height:56)
                        .position(x:rect.minX+70,y:rect.minY+38)
                }
            }
        }
        .allowsHitTesting(false)
        .onReceive(clock) { _ in
            model.request(feed:feed,renderer:renderer,histogram:histogram,zebras:zebras,focusPeaking:focusPeaking)
        }
        .onChange(of:histogram) { _,_ in model.invalidate() }
        .onChange(of:zebras) { _,_ in model.invalidate() }
        .onChange(of:focusPeaking) { _,_ in model.invalidate() }
        .onDisappear { model.invalidate() }
    }

    private func histogramView(_ snapshot: PreviewAssistSnapshot) -> some View {
        VStack(spacing:3) {
            HStack {
                Text("LUMA")
                Spacer(minLength:0)
                Text(String(format:"%.1f%% CLIP",snapshot.highlightFraction*100))
            }
            .font(.system(size:8,weight:.semibold,design:.monospaced))
            Canvas { context,size in
                let maximum = max(0.00001,snapshot.histogram.max() ?? 0)
                let step = size.width/CGFloat(snapshot.histogram.count)
                var path = Path()
                for (index,value) in snapshot.histogram.enumerated() {
                    let height = CGFloat(value/maximum)*size.height
                    path.addRect(CGRect(x:CGFloat(index)*step,y:size.height-height,width:max(1,step-0.5),height:height))
                }
                context.fill(path,with:.color(.white.opacity(0.85)))
            }
        }
        .foregroundStyle(.white)
        .padding(6)
        .background(.black.opacity(0.5),in:RoundedRectangle(cornerRadius:6))
        .accessibilityElement(children:.ignore)
        .accessibilityLabel("Preview luminance histogram")
        .accessibilityValue(String(format:"%.1f percent highlights near clipping",snapshot.highlightFraction*100))
    }
}
