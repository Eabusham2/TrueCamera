import AVFoundation
import Foundation

/// The exact resources AVFoundation delivered. No image renderer is involved.
struct PhotoPacket {
    let data: Data?
    let rawData: Data?
    let liveMovie: URL?
    let timestamp: CMTime
    let settings: CameraSettings
    let step: PhotoCaptureStep
    let processedFileExtension: String
    let dimensions: CMVideoDimensions
    let rawDimensions: CMVideoDimensions
    let captureDate: Date
    let pairID: UUID?
    let hasDepthData: Bool
    let hasPortraitEffectsMatte: Bool
    let hasCalibrationData: Bool
    /// A failed companion must never make a successfully delivered original vanish.
    let warning: String?
}

/// Requests the largest *lossless* ProRAW representation exposed by the system.
/// Quality 1 is lossless compression; it does not mean an uncompressed sensor dump.
final class LosslessProRAWRepresentation: NSObject, AVCapturePhotoFileDataRepresentationCustomizer {
    func replacementAppleProRAWCompressionSettings(for photo: AVCapturePhoto,
        defaultSettings: [String: Any], maximumBitDepth: Int) -> [String: Any] {
        [AVVideoQualityKey: 1.0, AVVideoAppleProRAWBitDepthKey: maximumBitDepth]
    }
    // Deliberately omit replacementMetadata: retain EXIF, GPS, DNG and Live pairing.
}

final class PhotoCapture: NSObject, AVCapturePhotoCaptureDelegate {
    let id: Int64
    private let settings: CameraSettings
    private let step: PhotoCaptureStep
    private let liveURL: URL?
    private let processedFileExtension: String
    private var captureDate: Date
    private let pairID: UUID?
    private let completion: (Result<PhotoPacket, Error>) -> Void
    private let lock = NSLock()
    private let representation = LosslessProRAWRepresentation()
    private var imageData: Data?
    private var rawData: Data?
    private var timestamp: CMTime = .invalid
    private var hasDepthData = false
    private var hasPortraitEffectsMatte = false
    private var hasCalibrationData = false
    private var liveFinished = false
    private var completed = false
    private var error: Error?

    init(id: Int64, settings: CameraSettings, step: PhotoCaptureStep, liveURL: URL?,
         processedFileExtension: String, pairID: UUID?, captureDate: Date = Date(),
         completion: @escaping (Result<PhotoPacket, Error>) -> Void) {
        self.id = id; self.settings = settings; self.step = step; self.liveURL = liveURL
        self.processedFileExtension = processedFileExtension; self.captureDate = captureDate
        self.pairID = pairID; self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        lock.lock(); defer { lock.unlock() }
        if !completed { captureDate = Date() }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        lock.lock(); defer { lock.unlock() }
        guard !completed else { return }
        if let error { self.error = error; return }
        let encoded = photo.isRawPhoto && step.rawKind == .appleProRAW
            ? photo.fileDataRepresentation(with: representation) : photo.fileDataRepresentation()
        guard let data = encoded, !data.isEmpty else {
            self.error = CameraFailure.message("The camera returned an empty photo resource."); return
        }
        if photo.isRawPhoto { rawData = data; if !timestamp.isValid { timestamp = photo.timestamp } }
        else if imageData == nil {
            imageData = data
            timestamp = photo.timestamp
            hasDepthData = photo.depthData != nil
            hasPortraitEffectsMatte = photo.portraitEffectsMatte != nil
            hasCalibrationData = photo.cameraCalibrationData != nil
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL,
                     duration: CMTime, photoDisplayTime: CMTime, resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        lock.lock(); defer { lock.unlock() }
        guard !completed else { return }
        if let error { self.error = error; return }
        let size = (try? outputFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        liveFinished = liveURL == outputFileURL && duration.isValid && duration.seconds > 0 && size > 0
        if !liveFinished { self.error = CameraFailure.message("Live Photo motion was not delivered; the capture was not silently converted to a still.") }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        var failure = error ?? self.error
        if step.rawKind != .none && rawData == nil {
            failure = failure ?? CameraFailure.message("The requested RAW resource was not delivered.")
        }
        if step.live && !liveFinished {
            failure = failure ?? CameraFailure.message("The requested Live Photo motion resource was not delivered.")
        }
        if imageData == nil {
            failure = failure ?? CameraFailure.message("The processed companion did not finish; no substitute image was generated.")
        }
        let data = imageData, raw = rawData, time = timestamp, date = captureDate
        let completedMovie = liveFinished ? liveURL : nil
        let depth = hasDepthData, matte = hasPortraitEffectsMatte, calibration = hasCalibrationData
        lock.unlock()
        if data != nil || raw != nil || completedMovie != nil {
            completion(.success(PhotoPacket(data: data, rawData: raw, liveMovie: completedMovie,
                timestamp: time, settings: settings, step: step, processedFileExtension: processedFileExtension,
                dimensions: resolvedSettings.photoDimensions, rawDimensions: resolvedSettings.rawPhotoDimensions,
                captureDate: date, pairID: pairID,
                hasDepthData: depth, hasPortraitEffectsMatte: matte, hasCalibrationData: calibration,
                warning: failure?.localizedDescription)))
        } else {
            completion(.failure(failure ?? CameraFailure.message("No photo resources were delivered.")))
        }
    }
}
