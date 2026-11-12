import Foundation
import CoreImage
import Metal
import CoreVideo

struct PreviewFrame {
    let image: CIImage
    let recordingImage: CIImage
    let overview: CIImage
    let plan: CropPlan
    let recordingPlan: CropPlan
    let target: Point2?
    let trackingGood: Bool
    let diagnostics: FrameDiagnostics
}
/// Holds only ONE latest frame. Slow UI consumers cannot accumulate camera buffers.
final class PreviewFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var value: PreviewFrame?
    func publish(_ frame: PreviewFrame?) { lock.lock(); value = frame; lock.unlock() }
    func snapshot() -> PreviewFrame? { lock.lock(); defer { lock.unlock() }; return value }
}
final class ImageRenderer: @unchecked Sendable {
    let device: MTLDevice
    let context: CIContext
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let videoColorSpace = CGColorSpace(name: CGColorSpace.itur_709)!
    init?() {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.device = device
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false,
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
    }
    func transform(_ image: CIImage, plan: CropPlan) -> CIImage {
        let c = cos(plan.angle), s = sin(plan.angle), z = plan.scale
        let transform = CGAffineTransform(a: z*c, b: z*s, c: -z*s, d: z*c,
            tx: plan.output.width/2-z*(c*plan.center.x-s*plan.center.y),
            ty: plan.output.height/2-z*(s*plan.center.x+c*plan.center.y))
        // Extend edge texels only for the resampling filter footprint. Geometry
        // still constrains the entire output to the real sensor image.
        return image.clampedToExtent().transformed(by: transform).cropped(to: CGRect(x: 0, y: 0,
            width: plan.output.width, height: plan.output.height))
    }
    // This renderer only changes framing. Exposure, ISO, white balance and focus
    // belong to AVCaptureDevice, before capture. There are deliberately no
    // style, artificial blur, denoise, sharpening or image-generation stages.
    func render(_ image: CIImage, into buffer: CVPixelBuffer) {
        context.render(image, to: buffer, bounds: image.extent, colorSpace: colorSpace)
    }
    func renderVideo(_ image: CIImage, into buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,.shouldPropagate)
        CVBufferSetAttachment(buffer,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,.shouldPropagate)
        CVBufferSetAttachment(buffer,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2,.shouldPropagate)
        context.render(image,to:buffer,bounds:image.extent,colorSpace:videoColorSpace)
    }
}

/// All methods (except PreviewFeed) execute on CaptureEngine.frameQueue.
final class FrameProcessor {
    let motion: MotionService
    let renderer: ImageRenderer
    let preview = PreviewFeed()
    var settings = CameraSettings()
    var front = false
    private var horizon = HorizonEstimator()
    private var lastAngle = 0.0
    private var manualCenter = Point2(0.5, 0.5)
    private var zoomAnchor: (target: Point2, anchor: Point2)?
    private var renderedZoom = 1.0
    private var zoomTimestamp: Double?
    private var actionOffset = Point2(0,0)
    private var actionTimestamp: Double?
    private var frameLockOffset = Point2(0,0)
    private var frameLockTimestamp: Double?
    private var horizontalFOVDegrees = 70.0
    private var pendingTarget: Point2?
    private(set) var lastPlan: CropPlan?
    private var frozenAngle: Double?
    private var recording = false
    private var planHistory: [(Double, CropPlan)] = []
    private var fpsStart = 0.0
    private var fpsCount = 0
    private var fps = 0.0
    var dropped = 0
    init(motion: MotionService, renderer: ImageRenderer) { self.motion = motion; self.renderer = renderer }
    func resetGeometry(keepPreview: Bool = false) {
        horizon.reset(); manualCenter = Point2(0.5, 0.5)
        zoomAnchor = nil; zoomTimestamp = nil; actionOffset = Point2(0,0); actionTimestamp = nil; frameLockOffset = Point2(0,0); frameLockTimestamp = nil; pendingTarget = nil; lastPlan = nil; lastAngle = 0
        renderedZoom = settings.zoom
        if !keepPreview { preview.publish(nil) }; fpsCount = 0; fpsStart = 0; planHistory.removeAll(); frozenAngle = nil
    }
    func beginRecording() { recording = true; frozenAngle = lastPlan?.angle }
    func endRecording() { recording = false; frozenAngle = nil }
    func configure(_ next: CameraSettings, front: Bool, horizontalFOVDegrees: Double? = nil) {
        let geometryReset = self.front != front || settings.framing != next.framing || settings.mirrorSelfie != next.mirrorSelfie
        if geometryReset { resetGeometry(keepPreview:true) }
        if settings.zoomLock != next.zoomLock { pendingTarget = nil; zoomAnchor = nil; frameLockOffset = .zero; frameLockTimestamp = nil }
        if settings.actionStabilization != next.actionStabilization || settings.smartArtifactGuard != next.smartArtifactGuard {
            actionOffset = Point2(0,0); actionTimestamp = nil
        }
        self.settings = next; self.front = front
        if let horizontalFOVDegrees, horizontalFOVDegrees.isFinite, horizontalFOVDegrees > 1 { self.horizontalFOVDegrees = horizontalFOVDegrees }
        if geometryReset { renderedZoom = next.zoom; zoomTimestamp = nil }
    }
    /// UIKit tap normalized to TOP-left, converted exactly through the saved render transform.
    func selectTarget(atUIKit point: Point2) { pendingTarget = Point2(point.x, 1-point.y) }
    func setZoom(_ zoom: Double, atUIKit point: Point2?) {
        guard zoom.isFinite else { return }
        if let point, let plan = lastPlan, !settings.zoomLock {
            let anchor = Point2(point.x, 1-point.y)
            let source = plan.outputToSource(Point2(anchor.x*plan.output.width, anchor.y*plan.output.height))
            zoomAnchor = (Point2(source.x/plan.source.width, source.y/plan.source.height), anchor)
        }
        settings.zoom = min(max(zoom, 1), 12)
    }
    func normalizedDevicePoint(atUIKit point: Point2) -> CGPoint? {
        guard let p = lastPlan else { return nil }
        let s = p.outputToSource(Point2(point.x*p.output.width, (1-point.y)*p.output.height))
        var x = CropGeometry.clamp(s.x/p.source.width, 0, 1)
        let y = CropGeometry.clamp(s.y/p.source.height, 0, 1)
        if front && settings.mirrorSelfie { x = 1-x }
        return CGPoint(x: 1-y, y: 1-x)
    }
    func process(buffer: CVPixelBuffer, hostTime: Double) throws -> PreviewFrame {
        guard hostTime.isFinite else { throw GeometryError.invalidInput }
        var source = CIImage(cvPixelBuffer: buffer)
        if front && settings.mirrorSelfie { source = source.oriented(.upMirrored) }
        source = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
        let size = Size2(source.extent.width, source.extent.height)
        var diagnostics = FrameDiagnostics()
        let reading = motion.sample(at: hostTime + settings.motionOffsetMilliseconds/1000)
        if let reading {
            let solution = horizon.update(reading, unmirroredFront: front && !settings.mirrorSelfie)
            lastAngle = solution.angle
            diagnostics.motionStatus = solution.gravityReliable ? "Horizon locked" : "Vertical view — gyro hold"
        } else {
            diagnostics.motionStatus = motion.available ? "Motion stale — holding angle" : "Motion unavailable"
        }

        // Zoom Lock is a floating sensor crop, not a subject-only tracker. Integrate
        // camera pitch/yaw so the selected framing stays fixed until the real sensor
        // boundary is reached. CropGeometry clamps at the edge; we then saturate the
        // integrator there so reversing direction immediately gives travel back.
        if settings.zoomLock, let reading {
            let dt = min(0.05, max(0, hostTime - (frameLockTimestamp ?? hostTime)))
            let delta = FrameLockMath.delta(rateX: reading.rateX, rateY: reading.rateY, dt: dt,
                                            horizontalFOVDegrees: horizontalFOVDegrees,
                                            sourceAspect: size.width / max(1, size.height))
            frameLockOffset = frameLockOffset + delta
            frameLockTimestamp = hostTime
        } else if !settings.zoomLock {
            frameLockOffset = .zero; frameLockTimestamp = hostTime
        }

        // Smart and Action share the same timestamp-aligned gyro path but stay out of
        // the live preview. Smart applies a gentler geometric correction;
        // Action applies the stronger fixed profile. Neither changes image color.
        let smartSteady = recording && settings.smartArtifactGuard && settings.mode.isMovie
        if recording && (settings.actionStabilization || smartSteady), let reading {
            let dt = min(0.05,max(0,hostTime-(actionTimestamp ?? hostTime)))
            let gain = settings.actionStabilization ? 0.32 : 0.11
            let decay = exp(-(settings.actionStabilization ? 1.7 : 3.2) * dt)
            let limit = settings.actionStabilization ? 0.18 : 0.065
            actionOffset = Point2(actionOffset.x*decay - reading.rateY*dt*gain,
                                  actionOffset.y*decay + reading.rateX*dt*gain)
            actionOffset.x = CropGeometry.clamp(actionOffset.x,-limit,limit)
            actionOffset.y = CropGeometry.clamp(actionOffset.y,-limit,limit)
            actionTimestamp = hostTime
        } else { actionOffset = Point2(0,0); actionTimestamp = hostTime }

        let previewAngle: Double
        if settings.horizonLock {
            previewAngle = lastAngle + settings.horizonTrimDegrees * .pi/180
        } else if settings.framing == .landscape {
            previewAngle = frozenAngle ?? ((reading?.gx ?? 1) >= 0 ? -.pi/2 : .pi/2)
        } else { previewAngle = 0; diagnostics.motionStatus = "Horizon off" }

        if let previous = zoomTimestamp {
            renderedZoom = ZoomTransition.step(current:renderedZoom,target:settings.zoom,deltaTime:max(0,hostTime-previous))
        } else { renderedZoom = settings.zoom }
        zoomTimestamp = hostTime

        var previewPlan = try CropGeometry.plan(source:size, output:settings.outputSize, angle:previewAngle,
            zoom:renderedZoom, fullTurn:settings.horizonLock, reserve:settings.previewReserve,
            requestedCenter:Point2((manualCenter.x+frameLockOffset.x)*size.width,
                                   (manualCenter.y+frameLockOffset.y)*size.height))

        if let pinch = zoomAnchor, !settings.zoomLock {
            let c = previewPlan.centerHolding(target:Point2(pinch.target.x*size.width,pinch.target.y*size.height),at:pinch.anchor)
            manualCenter = Point2(c.x/size.width,c.y/size.height)
            if abs(log2(renderedZoom/settings.zoom)) < 0.002 { zoomAnchor=nil }
            previewPlan = try CropGeometry.plan(source:size,output:settings.outputSize,angle:previewAngle,
                zoom:renderedZoom,fullTurn:settings.horizonLock,reserve:settings.previewReserve,
                requestedCenter:Point2(manualCenter.x*size.width,manualCenter.y*size.height))
        }
        if !settings.zoomLock && zoomAnchor == nil && (abs(manualCenter.x-0.5) > 0.0001 || abs(manualCenter.y-0.5) > 0.0001) {
            manualCenter = Point2(0.5,0.5)
            previewPlan = try CropGeometry.plan(source:size,output:settings.outputSize,angle:previewAngle,
                zoom:renderedZoom,fullTurn:settings.horizonLock,reserve:settings.previewReserve,
                requestedCenter:Point2(size.width/2,size.height/2))
        }

        if let target=pendingTarget {
            if settings.zoomLock {
                let p=(lastPlan ?? previewPlan).outputToSource(Point2(target.x*previewPlan.output.width,target.y*previewPlan.output.height))
                manualCenter=Point2(p.x/size.width,p.y/size.height)
                frameLockOffset = .zero
                frameLockTimestamp=hostTime
                previewPlan=try CropGeometry.plan(source:size,output:settings.outputSize,angle:previewAngle,
                    zoom:renderedZoom,fullTurn:settings.horizonLock,reserve:settings.previewReserve,
                    requestedCenter:Point2(manualCenter.x*size.width,manualCenter.y*size.height))
            }
            pendingTarget=nil
        }

        if settings.zoomLock && previewPlan.wasClamped {
            frameLockOffset = Point2(previewPlan.center.x/size.width-manualCenter.x,
                                     previewPlan.center.y/size.height-manualCenter.y)
        } else if !settings.zoomLock {
            manualCenter = Point2(previewPlan.center.x/size.width,previewPlan.center.y/size.height)
        }

        // Recording/output plan can be more aggressive than preview. Horizon and
        // Zoom Lock remain WYSIWYG; Action and Smart add output-only
        // motion/crop headroom so the viewfinder stays responsive and uncluttered.
        var captureAngle=previewAngle
        if !settings.horizonLock {
            let correction=AngleMath.wrap(lastAngle-previewAngle)
            if settings.actionStabilization { captureAngle = previewAngle + correction*0.82 }
            else if smartSteady { captureAngle = previewAngle + correction*0.14 }
        }
        let capturePlan: CropPlan
        if recording {
            let captureCenter = Point2(previewPlan.center.x + actionOffset.x*size.width,
                                       previewPlan.center.y + actionOffset.y*size.height)
            capturePlan = try CropGeometry.plan(source:size, output:settings.outputSize, angle:captureAngle,
                zoom:renderedZoom, fullTurn:settings.horizonLock, reserve:settings.captureReserve,
                requestedCenter:captureCenter)
        } else {
            capturePlan = previewPlan
        }

        lastPlan = previewPlan
        planHistory.append((hostTime,capturePlan))
        if planHistory.count > 600 { planHistory.removeFirst(planHistory.count-600) }

        let previewImage = renderer.transform(source,plan:previewPlan)
        let target = settings.zoomLock ? Point2(0.5,0.5) : nil
        if recording {
            let early=PreviewFrame(image:previewImage,recordingImage:previewImage,overview:source,plan:previewPlan,recordingPlan:previewPlan,target:target,trackingGood:settings.zoomLock && !previewPlan.wasClamped,diagnostics:diagnostics)
            preview.publish(early)
        }
        let recordingImage = recording ? renderer.transform(source,plan:capturePlan) : previewImage
        fpsCount += 1
        if fpsStart == 0 { fpsStart=hostTime }
        if hostTime-fpsStart >= 1 { fps=Double(fpsCount)/(hostTime-fpsStart); fpsStart=hostTime; fpsCount=0 }
        diagnostics.rollDegrees = lastAngle * 180 / .pi
        diagnostics.trackingStatus = settings.zoomLock ? (previewPlan.wasClamped ? "Edge" : "Locked") : "Off"
        diagnostics.confidence=0; diagnostics.edgeLimited=previewPlan.wasClamped
        diagnostics.detail=capturePlan.sourceDetail; diagnostics.upscaled=capturePlan.upscales
        diagnostics.deliveredFPS=fps; diagnostics.droppedFrames=dropped
        let frame=PreviewFrame(image:previewImage,recordingImage:recordingImage,overview:source,plan:previewPlan,recordingPlan:capturePlan,target:target,
            trackingGood:settings.zoomLock && !previewPlan.wasClamped,diagnostics:diagnostics)
        preview.publish(frame)
        return frame
    }
    /// Native photos can contain more vertical FOV than the video stream. First
    /// normalize their center crop to the preview's source aspect, then reuse
    /// the exact normalized crop center and lock transform at still exposure time.
    func processPhoto(_ input: CIImage, hostTime: Double) throws -> CIImage {
        guard let live = planHistory.min(by: { abs($0.0-hostTime) < abs($1.0-hostTime) })?.1 ?? lastPlan else { throw CameraFailure.message("The camera is not ready for a photo yet.") }
        var image = input
        if front && settings.mirrorSelfie { image = image.oriented(.upMirrored) }
        let e = image.extent, ratio = live.source.width/live.source.height
        let cropW = min(e.width, e.height*ratio), cropH = min(e.height, e.width/ratio)
        image = image.cropped(to: CGRect(x: e.midX-cropW/2,y: e.midY-cropH/2,width: cropW,height: cropH))
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX,y: -image.extent.minY))
        let size = Size2(image.extent.width,image.extent.height)
        var angle = live.angle
        if settings.horizonLock, let m = motion.sample(at: hostTime+settings.motionOffsetMilliseconds/1000) {
            var estimator = horizon
            angle = estimator.update(m, unmirroredFront: front && !settings.mirrorSelfie).angle + settings.horizonTrimDegrees * .pi/180
        }
        // Never advertise a full-resolution locked still by merely upscaling it.
        let maxEdge = max(2, Int(max(live.sourceDetail.width,live.sourceDetail.height)*size.width/live.source.width))
        let out = settings.framing.size(longEdge: maxEdge)
        let p = try CropGeometry.plan(source:size, output:out, angle:angle,zoom:live.zoom,
            fullTurn:settings.horizonLock,reserve:settings.reserve,
            requestedCenter:Point2(live.center.x/live.source.width*size.width,live.center.y/live.source.height*size.height))
        return renderer.transform(image,plan:p)
    }
}
