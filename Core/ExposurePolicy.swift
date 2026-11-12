import Foundation

/// Physical camera state sampled on the capture session queue. Durations are seconds;
/// timestamps are host-clock seconds, never wall-clock/EXIF dates.
public struct CameraTelemetry: Sendable, Equatable {
    public var revision: UInt64 = 0
    public var iso: Double = 100
    public var minISO: Double = 25
    public var maxISO: Double = 1600
    public var exposureDuration: Double = 1 / 120
    public var minExposureDuration: Double = 1 / 8000
    public var maxExposureDuration: Double = 1
    public var exposureTargetOffset: Double = 0
    public var exposureTargetBias: Double = 0
    public var aperture: Double = 1.8
    public var minAperture: Double = 0
    public var maxAperture: Double = 0
    public var isVideo = false
    public var fps: Double = 30
    public var whiteBalanceKelvin: Double = 5500
    public var whiteBalanceTint: Double = 0
    public var gyroRadiansPerSecond: Double = 0
    public var isFront = false
    public init() {}
    public var hasValidExposure: Bool {
        [iso,minISO,maxISO,exposureDuration,minExposureDuration,maxExposureDuration,
         exposureTargetOffset,exposureTargetBias,aperture,fps,gyroRadiansPerSecond].allSatisfy(\.isFinite) &&
        iso > 0 && minISO > 0 && maxISO >= minISO && exposureDuration > 0 &&
        minExposureDuration > 0 && maxExposureDuration >= minExposureDuration &&
        aperture > 0 && (!isVideo || fps > 0)
    }
}

public enum AIWhiteBalanceMode: String, Sendable, Equatable {
    case continuous, holdCurrent
}

/// A proposal, never an instruction to bypass device capability checks. The session
/// queue must re-check revision, expiry, state and manual ownership before applying.
public struct CameraDecision: Sendable, Equatable {
    public var revision: UInt64
    public var timestamp: Double
    public var validUntil: Double
    public var iso: Double?
    public var shutterSeconds: Double?
    public var exposureBias: Double?
    /// Portrait, unmirrored image coordinates with the origin at top left.
    public var focusPoint: Point2?
    public var whiteBalanceMode: AIWhiteBalanceMode?
    public var aperture: Double?
    public var scene: String
    public var confidence: Double
    public var reason: String
    public init(revision: UInt64, timestamp: Double, validUntil: Double, iso: Double? = nil,
                shutterSeconds: Double? = nil, exposureBias: Double? = nil,
                focusPoint: Point2? = nil, whiteBalanceMode: AIWhiteBalanceMode? = nil,
                aperture: Double? = nil, scene: String = "Analyzing", confidence: Double = 0,
                reason: String = "") {
        self.revision=revision; self.timestamp=timestamp; self.validUntil=validUntil
        self.iso=iso; self.shutterSeconds=shutterSeconds; self.exposureBias=exposureBias
        self.focusPoint=focusPoint; self.whiteBalanceMode=whiteBalanceMode; self.aperture=aperture
        self.scene=scene; self.confidence=confidence; self.reason=reason
    }
    public func isCurrent(revision: UInt64, now: Double) -> Bool {
        now.isFinite && timestamp.isFinite && validUntil.isFinite && self.revision == revision &&
        now >= timestamp && now <= validUntil && validUntil >= timestamp
    }
}

public struct NeuralClassification: Sendable, Equatable {
    public let label: String
    public let confidence: Double
    public init(_ label: String, _ confidence: Double) {
        self.label=label
        self.confidence=confidence.isFinite ? min(max(confidence,0),1) : 0
    }
}

public struct SceneEvidence: Sendable, Equatable {
    public var classifications: [NeuralClassification] = []
    public var faceCount = 0
    public var focusPoint: Point2?
    public var focusConfidence = 0.0
    /// Displacement of the neural subject box per second in normalized image units.
    public var subjectMotion = 0.0
    public var clippedHighlightFraction = 0.0
    public var highlightPercentile = 0.9
    public var meanLuminance = 0.4
    public var redGreenRatio = 1.0
    public var blueGreenRatio = 1.0
    public init() {}
    public var confidence: Double {
        max(classifications.map(\.confidence).max() ?? 0,
            faceCount > 0 ? min(max(focusConfidence,0),1) : 0)
    }
    public var sceneLabel: String {
        if faceCount > 0 { return faceCount > 1 ? "People" : "Person" }
        guard let best=classifications.max(by:{$0.confidence < $1.confidence}), best.confidence >= 0.2 else {
            return "Scene uncertain"
        }
        return best.label.replacingOccurrences(of:"_",with:" ").capitalized
    }
    public func confidence(matching words: [String]) -> Double {
        classifications.reduce(0) { score,item in
            let tokens=item.label.lowercased().split(whereSeparator:{ !$0.isLetter && !$0.isNumber }).map(String.init)
            let matches=words.contains { word in tokens.contains(word) || tokens.contains(word+"s") }
            return matches ? max(score,item.confidence) : score
        }
    }
    public var isValid: Bool {
        [focusConfidence,subjectMotion,clippedHighlightFraction,highlightPercentile,
         meanLuminance,redGreenRatio,blueGreenRatio].allSatisfy(\.isFinite) &&
        subjectMotion >= 0 && (0...1).contains(clippedHighlightFraction) &&
        (0...1).contains(highlightPercentile) && (0...1).contains(meanLuminance)
    }
}

public struct AIControlOwnership: Sendable, Equatable {
    public var exposure = true
    public var focus = true
    public var whiteBalance = true
    public var aperture = true
    public init() {}
}

/// Avoid a one-frame saliency/face detection change moving focus to another object.
/// Small movements track immediately; a large handover needs a second observation.
public struct NeuralFocusContinuity: Sendable {
    private var current: Point2?
    private var lastConfirmed = -Double.infinity
    private var pending: Point2?
    private var pendingTime = -Double.infinity
    public init() {}

    public mutating func accept(_ point:Point2?,confidence:Double,timestamp:Double)->Point2? {
        guard timestamp.isFinite else { return nil }
        if timestamp-lastConfirmed > 2 { current=nil; pending=nil }
        guard let point, point.x.isFinite, point.y.isFinite, confidence.isFinite,
              confidence >= 0.45, (0...1).contains(point.x), (0...1).contains(point.y) else {
            pending=nil; return nil
        }
        guard let existing=current else {
            current=point; lastConfirmed=timestamp; pending=nil; return point
        }
        if (point-existing).length <= 0.18 {
            current=point; lastConfirmed=timestamp; pending=nil; return point
        }
        if let candidate=pending, (point-candidate).length <= 0.10,
           timestamp > pendingTime, timestamp-pendingTime <= 1.5 {
            current=point; lastConfirmed=timestamp; pending=nil; return point
        }
        pending=point; pendingTime=timestamp
        return existing
    }
}

/// Interprets trained Vision model outputs with a transparent, bounded physical
/// exposure optimizer. This policy is NOT a learned image-quality/rating model.
/// It changes capture controls only and never writes to any captured pixel buffer.
public enum ExposurePolicy {
    public static func propose(scene: SceneEvidence, telemetry: CameraTelemetry,
                               ownership: AIControlOwnership, timestamp: Double,
                               exposureCompensation: Double = 0,
                               whiteBalanceStable: Bool = false) -> CameraDecision? {
        guard timestamp.isFinite, exposureCompensation.isFinite,
              telemetry.hasValidExposure, scene.isValid else { return nil }
        var decision=CameraDecision(revision:telemetry.revision,timestamp:timestamp,
                                    validUntil:timestamp+1.25,scene:scene.sceneLabel,
                                    confidence:scene.confidence)
        var reasons: [String] = []
        // Confidence in inference, not an assessment of photograph quality.
        let hasSceneEvidence=scene.confidence >= 0.2
        let activeSubject=max(scene.confidence(matching:["sport","running","racing","cycling","skiing"]),
                              max(scene.confidence(matching:["bird","dog","cat","animal"]) * 0.65,
                                  scene.faceCount > 0 ? 0.35 : 0))
        let sceneMotionFloor=1.0 / (60 + activeSubject * 440)
        let measuredMotionFloor=1.0 / (60 + min(scene.subjectMotion,2)*1800 +
                                          min(abs(telemetry.gyroRadiansPerSecond),4)*700)
        let safeShutter=min(sceneMotionFloor,measuredMotionFloor)

        if ownership.aperture && hasSceneEvidence && telemetry.minAperture.isFinite &&
            telemetry.maxAperture.isFinite && telemetry.minAperture > 0 &&
            telemetry.maxAperture > telemetry.minAperture + 0.05 {
            // Preserve light for moving/low-light scenes. Greater depth of field is
            // useful for a stationary broad scene only when light allows it.
            let broadScene=scene.confidence(matching:["landscape","architecture","building","scenery"])
            let wideOpenShutter=telemetry.exposureDuration*pow(telemetry.minAperture/telemetry.aperture,2)
            let lightThreshold=telemetry.aperture > telemetry.minAperture+0.2 ? 1.0/180 : 1.0/250
            let ampleLight=telemetry.iso <= telemetry.minISO*2 && wideOpenShutter < lightThreshold
            let desired=(broadScene >= 0.35 && ampleLight && activeSubject < 0.25) ? 4.0 : telemetry.minAperture
            decision.aperture=clamp(desired,telemetry.minAperture,telemetry.maxAperture)
            reasons.append(ampleLight && broadScene >= 0.35 ? "Depth of field" : "Available light")
        }
        if ownership.exposure && hasSceneEvidence {
            // Metering remains tied to the sensor's AE target, not a requirement to
            // force every dark/bright real scene to middle gray in a post-process.
            let clipped=scene.clippedHighlightFraction
            let highlightPenalty=clipped > 0.008 ? min(1.0,log2(1+clipped*16)) : 0
            let desiredBias=clamp(exposureCompensation-highlightPenalty,-3,3)
            let correction=clamp(desiredBias-telemetry.exposureTargetBias-telemetry.exposureTargetOffset,-0.4,0.4)
            let newAperture=decision.aperture ?? telemetry.aperture
            let apertureRatio=pow(newAperture/telemetry.aperture,2)
            let targetProduct=telemetry.iso*telemetry.exposureDuration*pow(2,correction)*apertureRatio
            guard targetProduct.isFinite && targetProduct > 0 else { return nil }
            var maxDuration=telemetry.maxExposureDuration
            if telemetry.isVideo { maxDuration=min(maxDuration,1/telemetry.fps) }
            guard maxDuration >= telemetry.minExposureDuration else { return nil }
            let preferred=clamp(safeShutter,telemetry.minExposureDuration,maxDuration)
            var candidates: [Double] = [telemetry.minExposureDuration,maxDuration,
                                        clamp(telemetry.exposureDuration,telemetry.minExposureDuration,maxDuration),
                                        preferred,clamp(targetProduct/telemetry.minISO,telemetry.minExposureDuration,maxDuration)]
            let lower=log2(telemetry.minExposureDuration), upper=log2(maxDuration)
            if upper > lower {
                for step in 0...48 { candidates.append(pow(2,lower+(upper-lower)*Double(step)/48)) }
            }
            var best: (score:Double,duration:Double,iso:Double)?
            for duration in candidates {
                let iso=clamp(targetProduct/duration,telemetry.minISO,telemetry.maxISO)
                let exposureError=log2(max(1e-12,iso*duration/targetProduct))
                let noise=max(0,log2(iso/telemetry.minISO))
                let blur=max(0,log2(duration/preferred))
                let change=abs(log2(duration/telemetry.exposureDuration))
                let score=exposureError*exposureError*12 + noise*0.16 + blur*blur*1.8 + change*0.025
                if best == nil || score < best!.score { best=(score,duration,iso) }
            }
            if let best, best.duration.isFinite, best.iso.isFinite {
                decision.iso=best.iso; decision.shutterSeconds=best.duration; decision.exposureBias=desiredBias
                if clipped > 0.008 { reasons.append("Protecting highlights") }
                reasons.append(activeSubject > 0.3 || scene.subjectMotion > 0.02 ? "Subject motion" : "Noise / detail balance")
            }
        }
        if ownership.focus, scene.focusConfidence >= 0.45, let point=scene.focusPoint,
           point.x.isFinite, point.y.isFinite {
            decision.focusPoint=Point2(clamp(point.x,0,1),clamp(point.y,0,1))
            reasons.append(scene.faceCount > 0 ? "Eye / face focus" : "Neural subject focus")
        }
        if ownership.whiteBalance && hasSceneEvidence {
            // The native AWB gains measure the illuminant. AI controls when to
            // reacquire/hold them; there are no warm/cool style offsets.
            decision.whiteBalanceMode=whiteBalanceStable ? .holdCurrent : .continuous
            reasons.append(whiteBalanceStable ? "White balance held" : "Measuring white balance")
        }
        decision.reason=reasons.isEmpty ? "Waiting for reliable scene evidence" : reasons.joined(separator:" · ")
        return decision
    }
    private static func clamp(_ x: Double,_ lo:Double,_ hi:Double)->Double { min(max(x,lo),hi) }
}
