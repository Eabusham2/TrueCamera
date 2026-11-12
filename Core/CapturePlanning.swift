import Foundation

/// A capture contract, separate from AVFoundation so combinations can be checked
/// before sending a request that would otherwise raise an Objective-C exception.
public enum RAWCaptureKind: String, Equatable, Sendable {
    case none, bayer, appleProRAW
}

public enum PhotoCapturePriority: String, CaseIterable, Equatable, Sendable {
    case speed = "Speed", balanced = "Balanced", quality = "Quality"
}

public struct PhotoCaptureStep: Equatable, Sendable {
    public let rawKind: RAWCaptureKind
    public let live: Bool
    public let maximumQuality: Bool
    public let exactExposure: Bool
    public let maximumResolution: Bool
    public let label: String
}

public enum PhotoPlanError: Error, Equatable, LocalizedError {
    case rawUnavailable
    case proRAWUnavailable
    case liveUnavailable
    case proRAWWithLive
    case exactMaximumConflict
    case bayerRAWZoom

    public var errorDescription: String? {
        switch self {
        case .rawUnavailable: return "Sensor RAW is unavailable on this lens and format. Choose another lens or turn RAW off."
        case .proRAWUnavailable: return "Apple ProRAW is unavailable on this lens and format. Choose another lens or select Sensor RAW."
        case .liveUnavailable: return "Live Photos are unavailable in this capture configuration. Choose a photo lens and format that supports Live Photos."
        case .proRAWWithLive: return "Apple ProRAW and Live Photos require separate exposures. Enable Dual photo to save both."
        case .exactMaximumConflict: return "Maximum-quality Dual capture lets Apple's photo pipeline choose exposure. Turn Exact exposure off, or turn Dual off for exact sensor exposure."
        case .bayerRAWZoom: return "Sensor RAW requires the selected physical lens at its native zoom, with no additional crop. Select a lens's native zoom button and wait for zoom to stop, or choose Apple ProRAW."
        }
    }
}

public enum PhotoCapturePlanner {
    public static func effectivePriority(for step: PhotoCaptureStep,
                                         requested: PhotoCapturePriority) -> PhotoCapturePriority {
        if step.exactExposure || step.rawKind == .bayer { return .speed }
        return step.maximumQuality ? .quality : requested
    }

    /// Apply this only to dimensions reported by the active format. Apple's
    /// WWDC26/304 table permits 12 MP at every priority, fused 18/24 MP only at
    /// Quality, and the full 48 MP sensor family at Balanced or Quality.
    /// Native 8064x6048 dimensions are 48.77 MP, despite the 48 MP family name.
    /// Other reported high resolutions conservatively require Quality.
    public static func supportsResolution(megapixels: Double, priority: PhotoCapturePriority) -> Bool {
        guard megapixels.isFinite, megapixels > 0 else { return false }
        if megapixels <= 13 { return true }
        switch priority {
        case .speed: return false
        case .balanced: return (46.0...50.0).contains(megapixels)
        case .quality: return true
        }
    }

    /// AVCapturePhotoOutput's Bayer RAW rules require both factors to be exactly
    /// 1.0 and prohibit zoom changes during capture. ProRAW has separate rules.
    public static func validateRAWZoom(rawKind: RAWCaptureKind, deviceZoomFactor: Double,
                                       connectionScaleAndCropFactor: Double,
                                       isZoomRamping: Bool) throws {
        guard rawKind == .bayer else { return }
        guard deviceZoomFactor == 1, connectionScaleAndCropFactor == 1,
              !isZoomRamping else { throw PhotoPlanError.bayerRAWZoom }
    }

    /// Never substitutes a processed image for a requested RAW or a still for Live.
    /// A dual pair always has two capture requests with distinct timestamps.
    public static func steps(dual: Bool, raw: Bool, preferProRAW: Bool,
                             live: Bool, exactExposure: Bool,
                             supportsBayerRAW: Bool, supportsProRAW: Bool,
                             supportsLive: Bool) throws -> [PhotoCaptureStep] {
        if dual {
            guard !exactExposure else { throw PhotoPlanError.exactMaximumConflict }
            guard supportsLive else { throw PhotoPlanError.liveUnavailable }
            let kind: RAWCaptureKind
            if preferProRAW {
                guard supportsProRAW else { throw PhotoPlanError.proRAWUnavailable }
                kind = .appleProRAW
            } else {
                guard supportsBayerRAW else { throw PhotoPlanError.rawUnavailable }
                kind = .bayer
            }
            return [
                PhotoCaptureStep(rawKind: kind, live: false,
                    maximumQuality: kind == .appleProRAW, exactExposure: kind == .bayer,
                    maximumResolution: true, label: kind == .appleProRAW ? "ProRAW master" : "Sensor RAW master"),
                PhotoCaptureStep(rawKind: .none, live: true, maximumQuality: true,
                    exactExposure: false, maximumResolution: true, label: "Live companion")
            ]
        }
        let kind: RAWCaptureKind = raw ? (preferProRAW ? .appleProRAW : .bayer) : .none
        if kind == .appleProRAW && !supportsProRAW { throw PhotoPlanError.proRAWUnavailable }
        if kind == .bayer && !supportsBayerRAW { throw PhotoPlanError.rawUnavailable }
        if live && !supportsLive { throw PhotoPlanError.liveUnavailable }
        if kind == .appleProRAW && live { throw PhotoPlanError.proRAWWithLive }
        return [PhotoCaptureStep(rawKind: kind, live: live,
            maximumQuality: false,
            exactExposure: exactExposure || kind == .bayer,
            maximumResolution: false,
            label: kind == .appleProRAW ? "Apple ProRAW" : (kind == .bayer ? "Sensor RAW" : (live ? "Live Photo" : "Photo")))]
    }

    /// Reject NaN/invalid durations and retain the hardware bounds for photos;
    /// a movie exposure is additionally bounded by its frame interval.
    public static func boundedShutter(_ seconds: Double, minimum: Double,
                                      maximum: Double, videoFPS: Double?) -> Double? {
        guard seconds.isFinite, seconds > 0, minimum.isFinite, minimum > 0,
              maximum.isFinite, maximum >= minimum else { return nil }
        var upper = maximum
        if let fps = videoFPS {
            guard fps.isFinite, fps > 0 else { return nil }
            upper = min(upper, 1 / fps)
        }
        guard upper >= minimum else { return nil }
        return min(max(seconds, minimum), upper)
    }
}
