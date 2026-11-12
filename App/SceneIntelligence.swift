import Foundation
import Vision
import CoreImage
import CoreVideo
import ImageIO

enum SceneIntelligenceState: String, Sendable {
    case idle = "Waiting", analyzing = "Analyzing", active = "AI active"
    case paused = "AI paused", unavailable = "AI unavailable"
}

struct SceneIntelligenceStatus: Sendable {
    var revision: UInt64 = 0
    var timestamp = 0.0
    var validUntil = 0.0
    var state: SceneIntelligenceState = .idle
    var scene = "Waiting for camera"
    var confidence = 0.0
    var reason = "On-device neural scene analysis"
    var latencyMS = 0.0
    var analysesPerSecond = 0.0
    var modelSummary = "Apple Vision · scene + saliency + faces"
    var histogram = [Double](repeating:0,count:32)
    var iso: Double?
    var shutterSeconds: Double?
    var aperture: Double?
    var focusPoint: Point2?
    var framesAnalyzed = 0
    var droppedAnalysisFrames = 0
    var summary: String { reason }
    init() {}
}

/// Read-only neural analysis of a reduced preview image. Exactly one input buffer
/// is retained at a time, and the preview/capture queues never wait for inference.
/// There is no image generation, neural denoising, tone mapping or output renderer.
final class SceneIntelligence: @unchecked Sendable {
    var onDecision: ((CameraDecision)->Void)?
    var onStatus: ((SceneIntelligenceStatus)->Void)?

    private let queue = DispatchQueue(label:"truecamera.scene-intelligence",qos:.utility)
    private let gate = NSLock()
    private let context = CIContext(options:[.cacheIntermediates:false])
    private var busy = false
    private var generation: UInt64 = 0
    private var lastAcceptedTime = -Double.infinity
    private var skipped = 0
    // Analysis-queue confined values below.
    private var processingGeneration: UInt64 = .max
    private var previousEvidence: SceneEvidence?
    private var previousTimestamp: Double?
    private var previousKelvin = 0.0
    private var previousTint = 0.0
    private var stableWhiteBalanceFrames = 0
    private var focusContinuity = NeuralFocusContinuity()
    private var analyzed = 0

    /// Call before changing the camera/lens/mode/control ownership or beginning a
    /// capture. In-flight neural work may finish, but it cannot publish a decision.
    func invalidate() {
        gate.lock()
        generation &+= 1
        lastAcceptedTime = -.infinity
        gate.unlock()
    }

    /// `pixelBuffer` must be the already-portrait, unmirrored video data output.
    /// `timestamp` uses the same host clock as the telemetry consumer's expiry test.
    func analyze(pixelBuffer: CVPixelBuffer, timestamp: Double,
                 settings: CameraSettings, telemetry: CameraTelemetry) {
        guard settings.aiEnabled, timestamp.isFinite else { return }
        let interval: Double
        switch ProcessInfo.processInfo.thermalState {
        case .serious: interval=1
        case .critical: interval=2
        default: interval=0.5
        }
        gate.lock()
        guard !busy, timestamp-lastAcceptedTime >= interval else {
            skipped += 1; gate.unlock(); return
        }
        busy=true; lastAcceptedTime=timestamp
        let ticket=generation, skippedFrames=skipped
        gate.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.gate.lock(); self.busy=false; self.gate.unlock() }
            guard self.isCurrent(ticket) else { return }
            if self.processingGeneration != ticket {
                self.processingGeneration=ticket
                self.previousEvidence=nil; self.previousTimestamp=nil
                self.stableWhiteBalanceFrames=0
                self.focusContinuity=NeuralFocusContinuity()
            }
            let start=ProcessInfo.processInfo.systemUptime
            autoreleasepool {
                do {
                    let result=try self.infer(pixelBuffer:pixelBuffer,timestamp:timestamp)
                    guard self.isCurrent(ticket) else { return }
                    var evidence=result.evidence
                    evidence.focusPoint=self.focusContinuity.accept(evidence.focusPoint,
                        confidence:evidence.focusConfidence,timestamp:timestamp)
                    let prior=self.previousEvidence
                    let interval=self.previousTimestamp.map { timestamp-$0 } ?? 0
                    let whiteBalanceStable=self.updateWhiteBalanceStability(evidence,telemetry:telemetry,prior:prior)
                    var ownership=AIControlOwnership()
                    ownership.exposure=settings.aiExposure && !settings.manualExposure && !settings.aeafLock
                    ownership.focus=settings.aiFocus && !settings.manualFocus && !settings.aeafLock
                    ownership.whiteBalance=settings.aiWhiteBalance && !settings.manualWhiteBalance && !settings.whiteBalanceLock
                    ownership.aperture=settings.aiAperture && !settings.manualAperture
                    let decision=ExposurePolicy.propose(scene:evidence,telemetry:telemetry,
                        ownership:ownership,timestamp:timestamp,
                        exposureCompensation:Double(settings.exposureEV),whiteBalanceStable:whiteBalanceStable)
                    self.previousEvidence=evidence; self.previousTimestamp=timestamp
                    self.analyzed += 1
                    var status=SceneIntelligenceStatus()
                    status.revision=telemetry.revision; status.timestamp=timestamp; status.validUntil=timestamp+1.25
                    status.state = .active
                    status.scene=evidence.sceneLabel; status.confidence=evidence.confidence
                    status.reason=decision?.reason ?? "Waiting for valid camera telemetry"
                    status.latencyMS=(ProcessInfo.processInfo.systemUptime-start)*1000
                    status.analysesPerSecond=interval > 0 ? min(2,1/interval) : 0
                    status.histogram=result.histogram
                    status.iso=decision?.iso; status.shutterSeconds=decision?.shutterSeconds
                    status.aperture=decision?.aperture; status.focusPoint=decision?.focusPoint
                    status.framesAnalyzed=self.analyzed; status.droppedAnalysisFrames=skippedFrames
                    guard self.isCurrent(ticket) else { return }
                    // The capture queue validates its own config revision/deadline.
                    if let decision { self.onDecision?(decision) }
                    self.onStatus?(status)
                } catch {
                    guard self.isCurrent(ticket) else { return }
                    var status=SceneIntelligenceStatus()
                    status.revision=telemetry.revision; status.timestamp=timestamp; status.validUntil=timestamp+1.25
                    status.state = .unavailable
                    status.reason="Vision could not analyze this frame: \(error.localizedDescription)"
                    status.latencyMS=(ProcessInfo.processInfo.systemUptime-start)*1000
                    status.framesAnalyzed=self.analyzed; status.droppedAnalysisFrames=skippedFrames
                    self.onStatus?(status)
                    // An inference failure does not masquerade as an AI proposal.
                    // The existing hardware state/manual controls remain available.
                }
            }
        }
    }

    private func isCurrent(_ ticket:UInt64)->Bool {
        gate.lock(); defer { gate.unlock() }
        return generation == ticket
    }

    struct InferenceResult {
        var evidence: SceneEvidence
        var histogram: [Double]
        var classificationCount: Int
        var performedNeuralRequests: Int
    }

    /// Internal synchronous entry point for executed iOS Vision integration tests.
    /// Production calls it only on `queue`, never on the frame/session/main queue.
    func infer(pixelBuffer:CVPixelBuffer,timestamp:Double) throws -> InferenceResult {
        let input=CIImage(cvPixelBuffer:pixelBuffer)
        let factor=min(1,512/max(input.extent.width,input.extent.height))
        let small=input.transformed(by:CGAffineTransform(scaleX:factor,y:factor))
        guard let image=context.createCGImage(small,from:small.extent,
                    format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)) else {
            throw IntelligenceError.unreadableFrame
        }
        let classification=VNClassifyImageRequest()
        let attention=VNGenerateAttentionBasedSaliencyImageRequest()
        let objects=VNGenerateObjectnessBasedSaliencyImageRequest()
        let faces=VNDetectFaceLandmarksRequest()
        let requests:[VNRequest]=[classification,attention,objects,faces]
        #if targetEnvironment(simulator)
        // The simulator does not have the phone's Neural Engine. This still runs
        // the actual Apple models; it never replaces them with fabricated results.
        for request in requests { request.usesCPUOnly=true }
        #endif
        try VNImageRequestHandler(cgImage:image,orientation:.up,options:[:]).perform(requests)
        var evidence=SceneEvidence()
        evidence.classifications=(classification.results ?? []).prefix(8).map {
            NeuralClassification($0.identifier,Double($0.confidence))
        }
        let detectedFaces=(faces.results ?? []).filter { $0.confidence >= 0.6 }
        evidence.faceCount=detectedFaces.count
        if let face=preferredFace(detectedFaces) {
            let point=Self.eyePoint(face) ?? CGPoint(x:face.boundingBox.midX,y:face.boundingBox.midY)
            evidence.focusPoint=Point2(Double(point.x),1-Double(point.y))
            evidence.focusConfidence=Double(face.confidence)
        } else {
            let attentionBoxes=attention.results?.first?.salientObjects ?? []
            let objectBoxes=objects.results?.first?.salientObjects ?? []
            let ranked=(objectBoxes+attentionBoxes).sorted { a,b in
                Self.subjectScore(a,previous:previousEvidence?.focusPoint) >
                    Self.subjectScore(b,previous:previousEvidence?.focusPoint)
            }
            if let subject=ranked.first, subject.confidence >= 0.45 {
                evidence.focusPoint=Point2(Double(subject.boundingBox.midX),1-Double(subject.boundingBox.midY))
                evidence.focusConfidence=Double(subject.confidence)
            }
        }
        if let point=evidence.focusPoint, let previous=previousEvidence?.focusPoint,
           let priorTime=previousTimestamp, timestamp > priorTime, timestamp-priorTime < 2.5 {
            // Motion of model-detected subjects is measured, not a fabricated
            // optical-flow claim. Gyro motion is an independent telemetry signal.
            evidence.subjectMotion=min(2,(point-previous).length/(timestamp-priorTime))
        }
        let stats=try Self.photometry(image)
        evidence.clippedHighlightFraction=stats.clipped
        evidence.highlightPercentile=stats.p95
        evidence.meanLuminance=stats.mean
        evidence.redGreenRatio=stats.redGreen
        evidence.blueGreenRatio=stats.blueGreen
        return InferenceResult(evidence:evidence,histogram:stats.histogram,
            classificationCount:classification.results?.count ?? 0,performedNeuralRequests:requests.count)
    }

    private func preferredFace(_ faces:[VNFaceObservation])->VNFaceObservation? {
        faces.max { a,b in
            Self.subjectScore(a,previous:previousEvidence?.focusPoint) <
                Self.subjectScore(b,previous:previousEvidence?.focusPoint)
        }
    }
    private static func subjectScore(_ observation:VNDetectedObjectObservation,previous:Point2?)->Double {
        let box=observation.boundingBox
        let center=Point2(Double(box.midX),1-Double(box.midY))
        let continuity=previous.map { max(0,1-(center-$0).length*3) } ?? 0
        return Double(observation.confidence)+sqrt(Double(box.width*box.height))*0.3+continuity*0.8
    }
    private static func eyePoint(_ face:VNFaceObservation)->CGPoint? {
        let regions=[face.landmarks?.leftEye,face.landmarks?.rightEye].compactMap {$0}
        let points=regions.flatMap { $0.normalizedPoints }
        guard !points.isEmpty else { return nil }
        let x=points.reduce(0.0) { $0+Double($1.x) }/Double(points.count)
        let y=points.reduce(0.0) { $0+Double($1.y) }/Double(points.count)
        return CGPoint(x:face.boundingBox.minX+CGFloat(x)*face.boundingBox.width,
                       y:face.boundingBox.minY+CGFloat(y)*face.boundingBox.height)
    }

    private func updateWhiteBalanceStability(_ scene:SceneEvidence,telemetry:CameraTelemetry,
                                            prior:SceneEvidence?)->Bool {
        defer { previousKelvin=telemetry.whiteBalanceKelvin; previousTint=telemetry.whiteBalanceTint }
        guard let prior, telemetry.whiteBalanceKelvin.isFinite, telemetry.whiteBalanceTint.isFinite else {
            stableWhiteBalanceFrames=0; return false
        }
        let changed=abs(scene.redGreenRatio-prior.redGreenRatio)>0.055 ||
                    abs(scene.blueGreenRatio-prior.blueGreenRatio)>0.055 ||
                    abs(scene.meanLuminance-prior.meanLuminance)>0.06 ||
                    abs(telemetry.whiteBalanceKelvin-previousKelvin)>120 ||
                    abs(telemetry.whiteBalanceTint-previousTint)>4 ||
                    scene.sceneLabel != prior.sceneLabel || scene.subjectMotion>0.06 ||
                    abs(telemetry.gyroRadiansPerSecond)>0.15
        stableWhiteBalanceFrames=changed ? 0 : min(20,stableWhiteBalanceFrames+1)
        // An illuminant/scene change re-enters native continuous AWB. Neutral
        // rendering never guesses that a red wall should be made gray.
        return stableWhiteBalanceFrames >= 5
    }

    struct Photometry {
        var histogram:[Double]
        var clipped:Double
        var p95:Double
        var mean:Double
        var redGreen:Double
        var blueGreen:Double
    }
    static func photometry(_ image:CGImage) throws -> Photometry {
        let width=96,height=96,row=96*4
        var bytes=[UInt8](repeating:0,count:row*height)
        let result:Photometry?=bytes.withUnsafeMutableBytes { memory in
            guard let cg=CGContext(data:memory.baseAddress,width:width,height:height,
                bitsPerComponent:8,bytesPerRow:row,space:CGColorSpaceCreateDeviceRGB(),
                bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            cg.interpolationQuality = .low
            cg.draw(image,in:CGRect(x:0,y:0,width:CGFloat(width),height:CGFloat(height)))
            guard let base=memory.baseAddress?.assumingMemoryBound(to:UInt8.self) else { return nil }
            var bins=[Double](repeating:0,count:32)
            var sum=0.0,red=0.0,green=0.0,blue=0.0,clipped=0.0
            let count=Double(width*height)
            for index in stride(from:0,to:row*height,by:4) {
                let r=Double(base[index])/255,g=Double(base[index+1])/255,b=Double(base[index+2])/255
                let luminance=0.2126*r+0.7152*g+0.0722*b
                bins[min(31,Int(luminance*32))] += 1
                sum += luminance; red += r; green += g; blue += b
                if min(r,min(g,b)) >= 0.985 { clipped += 1 }
            }
            var cumulative=0.0,p95=1.0
            for (index,value) in bins.enumerated() {
                cumulative += value
                if cumulative >= count*0.95 { p95=(Double(index)+0.5)/32; break }
            }
            return Photometry(histogram:bins.map {$0/count},clipped:clipped/count,p95:p95,mean:sum/count,
                              redGreen:red/max(green,1),blueGreen:blue/max(green,1))
        }
        guard let result else { throw IntelligenceError.unreadableFrame }
        return result
    }
    enum IntelligenceError: LocalizedError {
        case unreadableFrame
        var errorDescription:String? { "The camera preview frame could not be read." }
    }
}
