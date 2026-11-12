import Foundation
import AVFoundation
import CoreImage
import UIKit

public enum CaptureState: String { case stopped, starting, ready, recording, finishing, takingPhoto }

final class CaptureEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    let sessionQueue = DispatchQueue(label: "camera.session", qos: .userInitiated)
    let frameQueue = DispatchQueue(label: "camera.frames", qos: .userInteractive)
    let renderer: ImageRenderer
    let processor: FrameProcessor
    let motion = MotionService()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let metadataOutput = AVCaptureMetadataOutput()
    private let textDetector = LiveTextDetector()
    private let textQueue = DispatchQueue(label:"camera.live-text",qos:.utility)
    private var videoInput: AVCaptureDeviceInput?
    private var inputCache: [String:AVCaptureDeviceInput] = [:]
    private var audioInput: AVCaptureDeviceInput?
    private var devices: [AVCaptureDevice] = []
    private var configuration = CameraSettings()
    private var state: CaptureState = .stopped // sessionQueue only
    private var wantedRunning = false
    private var microphoneAllowed = false
    private var configured = false
    private var reportedCapabilities = CameraCapabilities()
    private var photoJobs: [Int64: PhotoCapture] = [:]
    private var photoSequenceInterrupted = false // sessionQueue only
    private var notifications: [NSObjectProtocol] = []
    private var movie: MovieRecorder? // frameQueue only
    private var recordingRestoreSettings: CameraSettings? // sessionQueue only
    private var recordingMinimumFrameTime = 0.0 // frameQueue only
    private var recordingSourceDimensions: CMVideoDimensions? // frameQueue only
    private var panorama: PanoramaAssembler? // frameQueue only
    private var lastDiagnosticsTime = 0.0
    private var lastSpaceCheck = 0.0
    private var lastTextTime = 0.0
    private var lastSmartFramingTime = 0.0
    private let intelligence = SceneIntelligence()
    private var configurationRevision: UInt64 = 0 // sessionQueue only
    private var lastAITime = 0.0 // frameQueue only
    private var aiMinimumFrameTime = 0.0 // sessionQueue only
    private let aiHandoffLock = NSLock()
    private var aiHandoffPending = false // protected by aiHandoffLock
    private var frameDevice: AVCaptureDevice? // frameQueue only
    private var lastTelemetryTime = 0.0 // sessionQueue only
    var onTelemetry: ((CameraTelemetry) -> Void)?
    var onQuickTakeActive: ((Bool) -> Void)?
    private var aiFocusHoldUntil = 0.0 // sessionQueue only; honor a user's tap
    var onAIStatus: ((SceneIntelligenceStatus) -> Void)?
    var onState: ((CaptureState) -> Void)?
    var onCapabilities: ((CameraCapabilities, CameraSettings) -> Void)?
    var onDiagnostics: ((FrameDiagnostics) -> Void)?
    var onMedia: ((Result<MediaDraft, Error>) -> Void)?
    var onCode: ((String) -> Void)?
    var onText: (([String]) -> Void)?
    var onControlSettings: ((CameraSettings) -> Void)?
    var onError: ((String) -> Void)?

    init(renderer: ImageRenderer) {
        self.renderer = renderer; processor = FrameProcessor(motion: motion, renderer: renderer)
        super.init()
        intelligence.onDecision = { [weak self] decision in
            self?.sessionQueue.async { [weak self] in self?.applyAIDecision(decision) }
        }
        intelligence.onStatus = { [weak self] status in
            self?.sessionQueue.async { [weak self] in
                guard let self, self.configuration.aiEnabled, status.revision == self.configurationRevision, status.validUntil >= ProcessInfo.processInfo.systemUptime, self.state == .ready || self.state == .recording else { return }
                DispatchQueue.main.async { [weak self] in self?.onAIStatus?(status) }
            }
        }
        let center = NotificationCenter.default
        notifications.append(center.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: nil) { [weak self] _ in
            self?.sessionQueue.async { [weak self] in
                guard let self else { return }
                if self.state == .takingPhoto { self.photoSequenceInterrupted = true }
                self.stopRecordingLocked()
                self.report("Camera interrupted by another app or a system event. Any recording is being finalized.")
            }
        })
        notifications.append(center.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: session, queue: nil) { [weak self] _ in
            self?.sessionQueue.async { [weak self] in
                guard let self, self.wantedRunning else { return }
                if !self.session.isRunning { self.session.startRunning() }
                if self.state != .recording && self.state != .finishing && self.state != .takingPhoto { self.setState(.ready) }
            }
        })
        notifications.append(center.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError
            self?.sessionQueue.async { [weak self] in
                guard let self else { return }
                if self.state == .takingPhoto { self.photoSequenceInterrupted = true }
                self.stopRecordingLocked()
                self.report(error?.localizedDescription ?? "The camera session stopped unexpectedly.")
                if error?.code == .mediaServicesWereReset, self.wantedRunning, self.state != .finishing {
                    self.session.startRunning()
                    if self.state != .takingPhoto { self.setState(.ready) }
                }
            }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            guard let value = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  value == AVAudioSession.InterruptionType.began.rawValue else { return }
            self?.stopRecording()
        })
        notifications.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
            if ProcessInfo.processInfo.thermalState == .critical {
                self?.suspend()
                self?.report("The iPhone is too hot. Recording was stopped; let it cool before resuming.")
            }
        })
    }
    deinit { notifications.forEach { NotificationCenter.default.removeObserver($0) }; motion.stop() }
    private func setState(_ next: CaptureState) {
        if next != .ready && next != .recording { invalidateAI() }
        state = next; DispatchQueue.main.async { [weak self] in self?.onState?(next) }
    }
    /// Session-queue-only capability used by the native output helper.
    var acceptsConfigurationChanges: Bool { state == .ready || state == .stopped || state == .starting }
    var acceptsRealtimeControlChanges: Bool { state == .ready || state == .recording }

    func setNativeRecordingActive(_ active: Bool) {
        sessionQueue.async { [self] in
            invalidateAI()
            setState(active ? .recording : (wantedRunning && session.isRunning ? .ready : .stopped))
        }
    }

    private func invalidateAI() {
        configurationRevision &+= 1
        aiMinimumFrameTime = ProcessInfo.processInfo.systemUptime
        intelligence.invalidate()
    }

    /// Called only on frameQueue. Native photo/movie zoom is already in its buffers.
    private func configurePreview(_ settings: CameraSettings, device: AVCaptureDevice) {
        frameDevice = device
        var preview = settings
        if settings.mode.isPhotoMode || settings.usesNativeMoviePipeline { preview.zoom = 1 }
        processor.configure(preview, front: device.position == .front,
            horizontalFOVDegrees: Double(device.activeFormat.videoFieldOfView))
    }

    /// Keep photo-output ownership here so live UI settings cannot undo the RAW/Live
    /// contract or lower the output's quality ceiling before the second exposure.
    func configurePhotoFeatures(_ settings: CameraSettings) {
        photoOutput.maxPhotoQualityPrioritization = .quality
        let wantsRAW = settings.raw || settings.dualPhotoCapture
        if photoOutput.isAppleProRAWSupported { photoOutput.isAppleProRAWEnabled = wantsRAW && settings.preferProRAW }
        photoOutput.isLivePhotoCaptureEnabled = photoOutput.isLivePhotoCaptureSupported &&
            settings.mode.isPhotoMode && (settings.livePhoto || settings.dualPhotoCapture)
        if photoOutput.isResponsiveCaptureSupported { photoOutput.isResponsiveCaptureEnabled = settings.responsiveCapture }
        if photoOutput.isZeroShutterLagSupported { photoOutput.isZeroShutterLagEnabled = settings.zeroShutterLag && !settings.exactExposure }
        if photoOutput.isFastCapturePrioritizationSupported {
            photoOutput.isFastCapturePrioritizationEnabled = settings.fastCapturePrioritization && !settings.dualPhotoCapture && !settings.exactExposure
        }
        // The delegate persists complete files. Never mislabel a deferred proxy as
        // the promised maximum-quality original.
        if photoOutput.isAutoDeferredPhotoDeliverySupported { photoOutput.isAutoDeferredPhotoDeliveryEnabled = false }
        if photoOutput.isDepthDataDeliverySupported { photoOutput.isDepthDataDeliveryEnabled = settings.depthData && !wantsRAW }
        if photoOutput.isPortraitEffectsMatteDeliverySupported { photoOutput.isPortraitEffectsMatteDeliveryEnabled = settings.portraitEffectsMatte && settings.depthData && !wantsRAW }
        photoOutput.enabledSemanticSegmentationMatteTypes = settings.semanticMattes && !wantsRAW ? photoOutput.availableSemanticSegmentationMatteTypes : []
        if #available(iOS 18.0, *), photoOutput.isConstantColorSupported { photoOutput.isConstantColorEnabled = settings.constantColor && !wantsRAW && !settings.exactExposure }
        if #available(iOS 26.0, *), photoOutput.isCameraSensorOrientationCompensationSupported {
            photoOutput.isCameraSensorOrientationCompensationEnabled = settings.sensorOrientationCompensation && !wantsRAW
        }
        if photoOutput.isContentAwareDistortionCorrectionSupported {
            photoOutput.isContentAwareDistortionCorrectionEnabled = settings.contentAwareDistortionCorrection && !settings.cameraCalibrationData && !wantsRAW
        }
    }

    private func cameraTelemetry(device: AVCaptureDevice) -> CameraTelemetry {
        var value = CameraTelemetry()
        value.revision = configurationRevision
        value.iso = Double(device.iso); value.minISO = Double(device.activeFormat.minISO); value.maxISO = Double(device.activeFormat.maxISO)
        value.exposureDuration = device.exposureDuration.seconds
        value.minExposureDuration = device.activeFormat.minExposureDuration.seconds
        value.maxExposureDuration = device.activeFormat.maxExposureDuration.seconds
        value.exposureTargetOffset = Double(device.exposureTargetOffset)
        value.exposureTargetBias = Double(device.exposureTargetBias)
        value.aperture = Double(device.lensAperture)
        let range = PhysicalApertureControl.range(for: device)
        value.minAperture = Double(range.lowerBound); value.maxAperture = Double(range.upperBound)
        value.isVideo = !configuration.mode.isPhotoMode
        value.fps = configuration.captureFPS
        value.isFront = device.position == .front
        let wb = device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains)
        value.whiteBalanceKelvin = Double(wb.temperature); value.whiteBalanceTint = Double(wb.tint)
        if let m = motion.sample(at: ProcessInfo.processInfo.systemUptime) {
            value.gyroRadiansPerSecond = sqrt(m.rateX*m.rateX + m.rateY*m.rateY + m.rateZ*m.rateZ)
        }
        return value
    }

    private func boundedWhiteBalanceGains(_ input: AVCaptureDevice.WhiteBalanceGains,
                                           device: AVCaptureDevice) -> AVCaptureDevice.WhiteBalanceGains {
        var gains = input
        func clamp(_ v: Float) -> Float { v.isFinite ? min(max(v, 1), device.maxWhiteBalanceGain) : 1 }
        gains.redGain = clamp(gains.redGain); gains.greenGain = clamp(gains.greenGain); gains.blueGain = clamp(gains.blueGain)
        return gains
    }

    private func applyAIDecision(_ decision: CameraDecision) {
        let now = ProcessInfo.processInfo.systemUptime
        guard state == .ready || state == .recording, configuration.aiEnabled,
              decision.isCurrent(revision: configurationRevision, now: now),
              let device = videoInput?.device, !device.isRampingVideoZoom else { return }
        do {
            try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
            let controlsExposure = configuration.aiExposure && !configuration.manualExposure && !configuration.aeafLock
            let controlsAperture = configuration.aiAperture && !configuration.manualAperture && !configuration.aeafLock
            var duration: CMTime?
            var iso: Float?
            if controlsExposure, let proposedISO = decision.iso, proposedISO.isFinite,
               let proposedShutter = decision.shutterSeconds,
               let bounded = PhotoCapturePlanner.boundedShutter(proposedShutter,
                    minimum: device.activeFormat.minExposureDuration.seconds,
                    maximum: device.activeFormat.maxExposureDuration.seconds,
                    videoFPS: configuration.mode.isPhotoMode ? nil : configuration.captureFPS),
               device.isExposureModeSupported(.custom) {
                duration = CMTime(seconds: bounded, preferredTimescale: 1_000_000_000)
                iso = Float(min(max(proposedISO, Double(device.activeFormat.minISO)), Double(device.activeFormat.maxISO)))
            }
            var appliedAperture = false
            if controlsAperture, let requested = decision.aperture, requested.isFinite {
                let range = PhysicalApertureControl.range(for: device)
                if range.upperBound > range.lowerBound + 0.01 {
                    let value = min(max(Float(requested), range.lowerBound), range.upperBound)
                    // Hold manually owned exposure values while AI changes the iris.
                    var shutter = duration, gain = iso
                    if configuration.manualExposure {
                        let requested = configuration.shutterAngleMode ? (configuration.shutterAngle / 360) / configuration.captureFPS : 1 / configuration.shutterDenominator
                        guard let bounded = PhotoCapturePlanner.boundedShutter(requested,
                            minimum: device.activeFormat.minExposureDuration.seconds,
                            maximum: device.activeFormat.maxExposureDuration.seconds,
                            videoFPS: configuration.mode.isPhotoMode ? nil : configuration.captureFPS) else { return }
                        shutter = CMTime(seconds: bounded, preferredTimescale: 1_000_000_000)
                        gain = min(max(configuration.iso, device.activeFormat.minISO), device.activeFormat.maxISO)
                    }
                    appliedAperture = PhysicalApertureControl.apply(value, device: device, duration: shutter, iso: gain)
                    guard appliedAperture else {
                        report("The camera rejected this AI aperture/exposure combination; the existing settings were preserved.")
                        return
                    }
                }
            }
            if !appliedAperture, let duration, let iso {
                if configuration.manualAperture {
                    guard PhysicalApertureControl.apply(configuration.aperture, device: device, duration: duration, iso: iso) else {
                        report("AI exposure could not preserve the selected physical aperture. Choose an exposure combination supported by this lens.")
                        return
                    }
                } else { device.setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil) }
            } else if duration == nil, controlsExposure, let bias = decision.exposureBias, bias.isFinite {
                device.setExposureTargetBias(min(max(Float(bias), device.minExposureTargetBias), device.maxExposureTargetBias), completionHandler: nil)
            }
            if configuration.aiFocus && !configuration.manualFocus && !configuration.aeafLock && now >= aiFocusHoldUntil,
               let point = decision.focusPoint, point.x.isFinite, point.y.isFinite, device.isFocusPointOfInterestSupported {
                // Inference sees the portrait UNMIRRORED source, before preview crop.
                let converted = CGPoint(x: min(max(point.y, 0), 1), y: 1 - min(max(point.x, 0), 1))
                let current = device.focusPointOfInterest
                if hypot(converted.x-current.x, converted.y-current.y) > 0.025 {
                    device.focusPointOfInterest = converted
                }
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            }
            if configuration.aiWhiteBalance && !configuration.manualWhiteBalance && !configuration.whiteBalanceLock,
               let mode = decision.whiteBalanceMode {
                switch mode {
                case .continuous:
                    if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
                case .holdCurrent:
                    if device.isWhiteBalanceModeSupported(.locked) {
                        device.setWhiteBalanceModeLocked(with: boundedWhiteBalanceGains(device.deviceWhiteBalanceGains, device: device), completionHandler: nil)
                    }
                }
            }
        } catch { report("AI camera controls could not be applied: \(error.localizedDescription)") }
    }

    private func report(_ message: String) { DispatchQueue.main.async { [weak self] in self?.onError?(message) } }
    private func deliver(_ result: Result<MediaDraft, Error>) {
        DispatchQueue.main.async { [weak self] in self?.onMedia?(result) }
    }
    private func publishControlSettings() {
        let snapshot = configuration
        DispatchQueue.main.async { [weak self] in self?.onControlSettings?(snapshot) }
    }
    func start(settings: CameraSettings, microphoneAllowed: Bool) {
        sessionQueue.async { [self] in
            wantedRunning = true; self.microphoneAllowed = microphoneAllowed
            guard state != .recording && state != .finishing && state != .takingPhoto else { return }
            setState(.starting)
            do {
                if microphoneAllowed {
                    let audio = AVAudioSession.sharedInstance()
                    try audio.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .allowBluetooth])
                    try audio.setActive(true)
                }
                try configure(settings, selected: videoInput?.device.uniqueID)
                motion.start()
                if !session.isRunning { session.startRunning() }
                guard session.isRunning else { throw CameraFailure.message("The camera could not start. Check permission and close other camera apps.") }
                setState(.ready)
            } catch { setState(.stopped); report(error.localizedDescription) }
        }
    }
    func suspend() {
        sessionQueue.async { [self] in
            wantedRunning = false
            invalidateAI()
            stopRecordingLocked()
            if session.isRunning { session.stopRunning() }
            motion.stop()
            if microphoneAllowed { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
            if state != .finishing && state != .takingPhoto { setState(.stopped) }
            frameQueue.async { [self] in processor.preview.publish(nil) }
        }
    }

    func pauseForExternalCapture(_ completion: @escaping () -> Void) {
        sessionQueue.async { [self] in
            wantedRunning = false
            invalidateAI()
            if state == .recording { stopRecordingLocked() }
            if session.isRunning { session.stopRunning() }
            motion.stop()
            if microphoneAllowed { try? AVAudioSession.sharedInstance().setActive(false,options:.notifyOthersOnDeactivation) }
            if state != .finishing && state != .takingPhoto { setState(.stopped) }
            frameQueue.async { [self] in processor.preview.publish(nil) }
            DispatchQueue.main.async { completion() }
        }
    }
    func update(_ settings: CameraSettings, lensID: String? = nil) {
        sessionQueue.async { [self] in
            guard state == .ready || state == .stopped || state == .recording else { return }
            let old = configuration, previousLens = videoInput?.device.uniqueID
            if state == .recording && (settings.requiresCaptureReconfiguration(comparedTo: old) ||
                (lensID != nil && lensID != previousLens)) {
                report("Stop recording before changing lens, format, frame rate or stabilization geometry.")
                return
            }
            if configured && settings == old && (lensID == nil || lensID == previousLens) { return }
            do {
                invalidateAI()
                if configured, let device = videoInput?.device,
                   (lensID == nil || lensID == previousLens),
                   !settings.requiresCaptureReconfiguration(comparedTo: old) {
                    try applyControls(settings, device: device)
                    for connection in [videoOutput.connection(with:.video),photoOutput.connection(with:.video)].compactMap({$0}) where connection.isVideoStabilizationSupported {
                        connection.preferredVideoStabilizationMode = NativeMovieController.preferredStabilization(settings,format:device.activeFormat)
                    }
                    configuration = settings
                    frameQueue.sync { [self] in configurePreview(settings, device: device) }
                    if #available(iOS 18.0, *) {
                        if old.manualFocus != settings.manualFocus && state != .recording {
                            configureCameraControls(settings,device:device)
                        } else { syncCameraControlValues(settings) }
                    }
                    let capabilities = reportedCapabilities
                    DispatchQueue.main.async { [weak self] in self?.onCapabilities?(capabilities, settings) }
                    return
                }
                try configure(settings, selected: lensID ?? previousLens)
            } catch {
                report(error.localizedDescription)
                if state == .recording {
                    // Reconfiguring activeFormat here could invalidate a native
                    // recording. Roll back only the realtime controls that failed.
                    if let device = videoInput?.device { try? applyControls(old, device: device) }
                    publishControlSettings()
                    return
                }
                do { try configure(old, selected: previousLens) }
                catch { report("The camera could not restore its previous configuration: \(error.localizedDescription)") }
            }
        }
    }
    private static func frameDuration(for fps: Double) -> CMTime {
        if abs(fps-23.976) < 0.02 { return CMTime(value:1001,timescale:24000) }
        if abs(fps-29.97) < 0.02 { return CMTime(value:1001,timescale:30000) }
        if abs(fps-59.94) < 0.02 { return CMTime(value:1001,timescale:60000) }
        return CMTime(seconds:1/max(1,fps),preferredTimescale:600_000)
    }
    private static func format(_ format: AVCaptureDevice.Format, meets resolution: Resolution) -> Bool {
        let d=CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let long=Int(max(d.width,d.height)), short=Int(min(d.width,d.height))
        switch resolution {
        case .hd: return long >= 1280 && short >= 720
        case .fullHD: return long >= 1920 && short >= 1080
        case .action2_8K: return long >= 2816 && short >= 1584
        case .ultraHD: return long >= 3840 && short >= 2160
        case .raw17x9: return long >= 4224 && short >= 2240
        case .openGate: return long >= 4224 && short >= 3024
        }
    }

    private func discover() {
        devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera,
            .builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
            mediaType: .video, position: .unspecified).devices
    }
    private func configure(_ settings: CameraSettings, selected id: String?) throws {
        if devices.isEmpty { discover() }
        guard let device = devices.first(where:{$0.uniqueID == id}) ??
                devices.first(where:{$0.position == .back && $0.deviceType == .builtInWideAngleCamera && !$0.isVirtualDevice}) ??
                devices.first(where:{$0.position == .back && $0.isVirtualDevice}) ?? devices.first else {
            throw CameraFailure.message("No camera is available. A physical iPhone is required to capture.")
        }
        let previousDeviceID = videoInput?.device.uniqueID
        let fps = settings.mode.isPhotoMode ? 30.0 : settings.captureFPS
        let stabilizationNeedsDetail = !settings.mode.isPhotoMode && settings.captureFPS <= 30 && (settings.horizonLock || settings.zoomLock)
        let targetWidth = settings.mode.isPhotoMode ? 1920 : (stabilizationNeedsDetail ? max(3840,settings.resolution.longEdge) : settings.resolution.longEdge)
        func maxPhotoArea(_ format: AVCaptureDevice.Format) -> Int64 {
            format.supportedMaxPhotoDimensions.map { Int64($0.width)*Int64($0.height) }.max() ?? 0
        }
        let eligible = device.formats.filter { f in
            let d=CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let baseOK=max(d.width,d.height) >= 1280 && min(d.width,d.height) >= 720
            let sizeOK=settings.mode.isPhotoMode || Self.format(f,meets:settings.resolution)
            return baseOK && sizeOK && f.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= fps+0.001 && $0.maxFrameRate >= fps-0.001 }
        }
        func codecPenalty(_ f: AVCaptureDevice.Format) -> Int {
            let subtype=f.formatDescription.mediaSubType.rawValue
            if settings.codec.isProResRAW {
                if #available(iOS 26.0, *), subtype == kCMVideoCodecType_AppleProResRAW || subtype == kCMVideoCodecType_AppleProResRAWHQ { return 0 }
                return 2
            }
            if settings.codec.isProRes { return subtype == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange ? 0 : 1 }
            return 0
        }
        let sorted = eligible.sorted { a,b in
            let ac=codecPenalty(a), bc=codecPenalty(b)
            if ac != bc { return ac < bc }
            if settings.mode.isPhotoMode {
                let ap = maxPhotoArea(a), bp = maxPhotoArea(b)
                if ap != bp { return ap > bp }
            }
            func score(_ f: AVCaptureDevice.Format) -> Double {
                let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                return abs(Double(d.width)-Double(targetWidth))*2 + abs(Double(d.height)-Double(targetWidth)*9/16)
            }
            return score(a) < score(b)
        }
        guard var format = sorted.first else { throw CameraFailure.message("This lens does not support \(fps) fps. Choose another lens or a lower frame rate.") }
        if !settings.mode.isPhotoMode && !Self.format(format,meets:settings.resolution) {
            throw CameraFailure.message("\(settings.resolution.rawValue) at this frame rate is not supported by this lens.")
        }
        let input: AVCaptureDeviceInput
        if let cached=inputCache[device.uniqueID] { input=cached }
        else { let created=try AVCaptureDeviceInput(device:device); inputCache[device.uniqueID]=created; input=created }
        session.beginConfiguration()
        do {
            // A retained movie output disables Live Photos even while idle.
            if settings.mode.isPhotoMode {
                for output in session.outputs.compactMap({ $0 as? AVCaptureMovieFileOutput }) where !output.isRecording {
                    session.removeOutput(output)
                }
            }
            session.sessionPreset = settings.mode.isPhotoMode ? .photo : .inputPriority
            session.automaticallyConfiguresApplicationAudioSession = false
            if videoInput?.device.uniqueID != device.uniqueID {
                if let old = videoInput { session.removeInput(old) }
                guard session.canAddInput(input) else {
                    if let old = videoInput, session.canAddInput(old) { session.addInput(old) }
                    throw CameraFailure.message("Could not switch to this camera.")
                }
                session.addInput(input); videoInput = input
            }
            if !configured {
                videoOutput.alwaysDiscardsLateVideoFrames = true
                videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
                videoOutput.setSampleBufferDelegate(self, queue: frameQueue)
                guard session.canAddOutput(videoOutput), session.canAddOutput(photoOutput) else {
                    throw CameraFailure.message("This camera cannot provide photo and video output.")
                }
                session.addOutput(videoOutput); session.addOutput(photoOutput)
                photoOutput.maxPhotoQualityPrioritization = .quality
                if session.canAddOutput(metadataOutput) {
                    session.addOutput(metadataOutput)
                    metadataOutput.setMetadataObjectsDelegate(self, queue: frameQueue)
                }
                configured = true
            }
            if microphoneAllowed && audioInput == nil, let microphone = AVCaptureDevice.default(for: .audio) {
                let mic = try AVCaptureDeviceInput(device: microphone)
                if session.canAddInput(mic) {
                    session.addInput(mic); audioInput = mic
                    if session.canAddOutput(audioOutput) {
                        session.addOutput(audioOutput); audioOutput.setSampleBufferDelegate(self, queue: frameQueue)
                    }
                }
            }
            if settings.mode.isPhotoMode {
                // Let the photo preset choose Apple's highest-quality photo format.
                // Setting activeFormat here would switch the session to inputPriority.
                session.sessionPreset = .photo
                format = device.activeFormat
            }
            try device.lockForConfiguration()
            if #available(iOS 26.0, *), input.isLockedVideoFrameDurationSupported,
               input.activeLockedVideoFrameDuration.isValid {
                input.activeLockedVideoFrameDuration = .invalid
            }
            if !settings.mode.isPhotoMode { device.activeFormat = format }
            device.automaticallyAdjustsVideoHDREnabled = false
            if device.isVideoHDREnabled { device.isVideoHDREnabled = false }
            let frameDuration=Self.frameDuration(for:fps)
            if !settings.mode.isPhotoMode {
                device.activeVideoMinFrameDuration=frameDuration
                device.activeVideoMaxFrameDuration=frameDuration
            } else {
                device.activeVideoMinFrameDuration = .invalid
                device.activeVideoMaxFrameDuration = .invalid
            }
            let nativeZoom = settings.mode.isPhotoMode || settings.usesNativeMoviePipeline
            device.videoZoomFactor = min(max(CGFloat(nativeZoom ? settings.zoom : 1), device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
            if device.isLowLightBoostSupported { device.automaticallyEnablesLowLightBoostWhenAvailable = true }
            if device.isSmoothAutoFocusSupported { device.isSmoothAutoFocusEnabled = true }
            device.isSubjectAreaChangeMonitoringEnabled = !settings.aeafLock
            device.unlockForConfiguration()
            if let max = format.supportedMaxPhotoDimensions.max(by: { Int64($0.width)*Int64($0.height) < Int64($1.width)*Int64($1.height) }) {
                photoOutput.maxPhotoDimensions = max
            }
            for connection in [videoOutput.connection(with: .video), photoOutput.connection(with: .video)].compactMap({ $0 }) {
                if connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = connection === photoOutput.connection(with: .video) &&
                        device.position == .front && settings.mirrorSelfie && !settings.isProcessedPhoto
                }
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = NativeMovieController.preferredStabilization(settings,format:format)
                }
            }
            configurePhotoFeatures(settings)
            if session.outputs.contains(where: { $0 === metadataOutput }) {
                metadataOutput.metadataObjectTypes = settings.scanQRCodes && metadataOutput.availableMetadataObjectTypes.contains(.qr) ? [.qr] : []
            }
            session.commitConfiguration()
        } catch { session.commitConfiguration(); throw error }
        try applyControls(settings, device: device)
        if #available(iOS 18.0, *) { configureCameraControls(settings,device:device) }
        let changedSource = configuration.mode != settings.mode || configuration.captureFPS != settings.captureFPS || configuration.resolution != settings.resolution ||
            configuration.horizonLock != settings.horizonLock || configuration.zoomLock != settings.zoomLock ||
            configuration.actionStabilization != settings.actionStabilization || previousDeviceID != device.uniqueID
        configuration = settings
        frameQueue.sync { [self] in
            if changedSource { processor.resetGeometry(keepPreview: previousDeviceID != nil && previousDeviceID != device.uniqueID) }
            configurePreview(settings, device: device)
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        var capabilities = CameraCapabilities()
        let wideFOV = devices.first(where: { $0.position == .back && $0.deviceType == .builtInWideAngleCamera })?.activeFormat.videoFieldOfView ?? 70
        capabilities.lenses = devices.filter { camera in
            camera.position == .front || !camera.isVirtualDevice
        }.map { camera -> LensOption in
            let front=camera.position == .front
            let factor=front ? 1.0 : tan(Double(wideFOV) * .pi / 360) / tan(Double(camera.activeFormat.videoFieldOfView) * .pi / 360)
            let label=front ? "Front" : (abs(factor-factor.rounded()) < 0.12 ? String(format:"%.0f×",factor) : String(format:"%.1f×",factor))
            let focalLengthMM = front ? 24 : max(1,Int((24.0 * factor).rounded()))
            return LensOption(id:camera.uniqueID,label:label,name:camera.localizedName,isFront:front,isVirtual:false,factor:max(0.5,factor),focalLengthMM:focalLengthMM)
        }.sorted {
            if $0.isFront != $1.isFront { return !$0.isFront }
            return $0.factor < $1.factor
        }
        capabilities.selectedLens = device.uniqueID
        capabilities.flash = device.hasFlash; capabilities.torch = device.hasTorch
        capabilities.livePhoto = photoOutput.isLivePhotoCaptureSupported
        capabilities.bayerRAW = photoOutput.availableRawPhotoPixelFormatTypes.contains(where: AVCapturePhotoOutput.isBayerRAWPixelFormat)
        capabilities.raw = capabilities.bayerRAW || photoOutput.isAppleProRAWSupported
        capabilities.proRAW = photoOutput.isAppleProRAWSupported
        capabilities.supportsDualPhoto = photoOutput.isLivePhotoCaptureSupported &&
            (settings.preferProRAW ? capabilities.proRAW : capabilities.bayerRAW)
        do {
            _ = try plannedPhotoSteps(settings)
        } catch { capabilities.photoCaptureReason = error.localizedDescription }
        capabilities.qrScanning = metadataOutput.availableMetadataObjectTypes.contains(.qr)
        capabilities.maxBracketedCaptureCount = photoOutput.maxBracketedCapturePhotoCount
        capabilities.bracketedCapture = photoOutput.maxBracketedCapturePhotoCount >= 2
        capabilities.multiCam = AVCaptureMultiCamSession.isMultiCamSupported
        capabilities.spatialPhoto = AVCaptureMultiCamSession.isMultiCamSupported && devices.filter { $0.position == .back && !$0.isVirtualDevice }.count >= 2
        capabilities.manualFocus = device.isLockingFocusWithCustomLensPositionSupported
        capabilities.maxISO = format.maxISO; capabilities.minISO = format.minISO
        capabilities.currentISO = device.iso
        capabilities.currentShutterSeconds = device.exposureDuration.seconds
        capabilities.minShutterSeconds = format.minExposureDuration.seconds
        capabilities.maxShutterSeconds = settings.mode.isPhotoMode ? format.maxExposureDuration.seconds : min(format.maxExposureDuration.seconds, 1 / fps)
        capabilities.currentAperture = device.lensAperture
        let aperture = PhysicalApertureControl.range(for: device)
        capabilities.minAperture = aperture.lowerBound
        capabilities.maxAperture = aperture.upperBound
        capabilities.supportsManualAperture = aperture.upperBound > aperture.lowerBound + 0.01
        capabilities.minEV = device.minExposureTargetBias; capabilities.maxEV = device.maxExposureTargetBias
        capabilities.supports4K = device.formats.contains { CMVideoFormatDescriptionGetDimensions($0.formatDescription).width >= 3840 }
        capabilities.supports60 = device.formats.contains { $0.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 60 } }
        capabilities.supports120 = device.formats.contains { $0.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 120 } }
        if settings.mode.isPhotoMode, let still = format.supportedMaxPhotoDimensions.max(by: { Int64($0.width)*Int64($0.height) < Int64($1.width)*Int64($1.height) }) {
            capabilities.sourceDescription = "\(dimensions.width)×\(dimensions.height) preview · still up to \(still.width)×\(still.height)"
        } else {
            capabilities.sourceDescription = "\(dimensions.width)×\(dimensions.height) sensor stream · \(String(format:"%.3g",fps)) fps"
        }
        reportedCapabilities = capabilities
        DispatchQueue.main.async { [weak self] in self?.onCapabilities?(capabilities,settings) }
    }
    @available(iOS 18.0, *)
    private func configureCameraControls(_ settings: CameraSettings, device: AVCaptureDevice) {
        guard session.supportsControls else { return }
        session.beginConfiguration()
        for control in session.controls { session.removeControl(control) }

        let zoom = AVCaptureSlider("Zoom", symbolName:"magnifyingglass", in:Float(1)...Float(12), step:0.1)
        zoom.accessibilityIdentifier = "horizon.zoom"
        zoom.localizedValueFormat = "%.1f×"
        zoom.value = Float(settings.zoom)
        zoom.setActionQueue(sessionQueue) { [weak self] value in
            guard let self else { return }
            let zoomValue = min(max(Double(value),1),12)
            self.setZoom(zoomValue)
        }

        var controls: [AVCaptureControl] = [zoom]
        if device.minExposureTargetBias < device.maxExposureTargetBias {
            let exposure = AVCaptureSystemExposureBiasSlider(device:device) { [weak self] value in
                guard let self else { return }
                self.sessionQueue.async { [weak self] in
                    guard let self else { return }
                    self.invalidateAI()
                    self.configuration.exposureEV = value
                    self.publishControlSettings()
                }
            }
            exposure.isEnabled = !settings.manualExposure && !settings.aeafLock
            controls.append(exposure)
        }
        if device.isLockingFocusWithCustomLensPositionSupported {
            let focus = AVCaptureSlider("Focus", symbolName:"scope", in:Float(0)...Float(1))
            focus.accessibilityIdentifier = "horizon.focus"
            focus.value = settings.manualFocus ? settings.lensPosition : device.lensPosition
            focus.setActionQueue(sessionQueue) { [weak self, weak device] value in
                guard let self, let device, self.acceptsRealtimeControlChanges else { return }
                do {
                    try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
                    device.setFocusModeLocked(lensPosition:min(max(value,0),1),completionHandler:nil)
                    self.invalidateAI()
                    self.configuration.manualFocus = true
                    self.configuration.aiFocus = false
                    self.configuration.lensPosition = min(max(value,0),1)
                    self.publishControlSettings()
                } catch { self.report(error.localizedDescription) }
            }
            controls.append(focus)
        }
        for control in controls where session.canAddControl(control) { session.addControl(control) }
        session.commitConfiguration()
        session.setControlsDelegate(self,queue:sessionQueue)
    }

    @available(iOS 18.0, *)
    private func syncCameraControlValues(_ settings: CameraSettings) {
        guard session.supportsControls else { return }
        for control in session.controls {
            if let exposure = control as? AVCaptureSystemExposureBiasSlider {
                exposure.isEnabled = !settings.manualExposure && !settings.aeafLock
                continue
            }
            guard let slider = control as? AVCaptureSlider else { continue }
            switch slider.accessibilityIdentifier {
            case "horizon.zoom":
                let value=Float(min(max(settings.zoom,1),12)); if abs(slider.value-value) > 0.001 { slider.value=value }
            case "horizon.focus":
                if settings.manualFocus { let value=min(max(settings.lensPosition,0),1); if abs(slider.value-value) > 0.001 { slider.value=value } }
            default: break
            }
        }
    }

    private func applyControls(_ settings: CameraSettings, device: AVCaptureDevice) throws {
        try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
        if settings.manualFocus && device.isLockingFocusWithCustomLensPositionSupported {
            device.setFocusModeLocked(lensPosition: min(max(settings.lensPosition,0),1), completionHandler: nil)
        } else {
            let mode: AVCaptureDevice.FocusMode = settings.aeafLock ? .locked : .continuousAutoFocus
            if device.isFocusModeSupported(mode) { device.focusMode = mode }
        }
        if settings.mode.isPhotoMode || settings.usesNativeMoviePipeline {
            let zoom = min(max(CGFloat(settings.zoom), device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
            if abs(device.videoZoomFactor - zoom) > 0.001 { device.videoZoomFactor = zoom }
        }
        if settings.manualExposure && device.isExposureModeSupported(.custom) {
            let requested = settings.shutterAngleMode ? (settings.shutterAngle / 360.0) / settings.captureFPS : 1 / settings.shutterDenominator
            guard let bounded = PhotoCapturePlanner.boundedShutter(requested,
                minimum: device.activeFormat.minExposureDuration.seconds,
                maximum: device.activeFormat.maxExposureDuration.seconds,
                videoFPS: settings.mode.isPhotoMode ? nil : settings.captureFPS) else {
                throw CameraFailure.message("The requested shutter duration is invalid for this camera format.")
            }
            let duration = CMTime(seconds: bounded, preferredTimescale: 1_000_000_000)
            let iso = min(max(settings.iso, device.activeFormat.minISO), device.activeFormat.maxISO)
            if settings.manualAperture {
                guard PhysicalApertureControl.apply(settings.aperture, device: device, duration: duration, iso: iso) else {
                    throw CameraFailure.message("This lens cannot apply the requested physical aperture with these exposure settings.")
                }
            } else { device.setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil) }
        } else if settings.manualAperture && !settings.aeafLock {
            guard PhysicalApertureControl.apply(settings.aperture, device: device, duration: nil, iso: nil) else {
                throw CameraFailure.message("Physical aperture priority requires a supported variable-aperture lens and iOS 27 build.")
            }
        } else {
            let mode: AVCaptureDevice.ExposureMode = settings.aeafLock ? .locked : .continuousAutoExposure
            if device.isExposureModeSupported(mode) { device.exposureMode = mode }
            device.setExposureTargetBias(min(max(settings.exposureEV, device.minExposureTargetBias), device.maxExposureTargetBias), completionHandler: nil)
        }
        if settings.manualWhiteBalance && device.isWhiteBalanceModeSupported(.locked) {
            let values=AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature:Float(settings.whiteBalanceKelvin),tint:Float(settings.whiteBalanceTint))
            var gains=device.deviceWhiteBalanceGains(for:values)
            gains.redGain=min(max(gains.redGain,1),device.maxWhiteBalanceGain)
            gains.greenGain=min(max(gains.greenGain,1),device.maxWhiteBalanceGain)
            gains.blueGain=min(max(gains.blueGain,1),device.maxWhiteBalanceGain)
            device.setWhiteBalanceModeLocked(with:gains,completionHandler:nil)
        } else if settings.whiteBalanceLock && device.isWhiteBalanceModeSupported(.locked) {
            var gains=device.deviceWhiteBalanceGains
            gains.redGain=min(max(gains.redGain,1),device.maxWhiteBalanceGain)
            gains.greenGain=min(max(gains.greenGain,1),device.maxWhiteBalanceGain)
            gains.blueGain=min(max(gains.blueGain,1),device.maxWhiteBalanceGain)
            device.setWhiteBalanceModeLocked(with:gains,completionHandler:nil)
        } else if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
        if device.hasTorch {
            if settings.torch && !settings.mode.isPhotoMode { try device.setTorchModeOn(level: 0.7) }
            else { device.torchMode = .off }
        }
    }
    func setZoom(_ zoom: Double, anchor: Point2? = nil) {
        let value = min(max(zoom,1),12)
        sessionQueue.async { [self] in
            guard acceptsRealtimeControlChanges else { return }
            invalidateAI()
            configuration.zoom = value
            if #available(iOS 18.0, *) { syncCameraControlValues(configuration) }
            let native = configuration.usesNativeMoviePipeline || configuration.mode.isPhotoMode
            if native, let device = videoInput?.device {
                do {
                    try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
                    let factor = min(max(CGFloat(value), device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
                    if device.isRampingVideoZoom { device.cancelVideoZoomRamp() }
                    device.ramp(toVideoZoomFactor: factor, withRate: 8)
                } catch { report(error.localizedDescription) }
            }
            frameQueue.async { [self] in processor.setZoom(native ? 1 : value, atUIKit: native ? nil : anchor) }
            publishControlSettings()
        }
    }
    func tap(_ point: Point2) {
        frameQueue.async { [self] in
            if processor.settings.zoomLock { processor.selectTarget(atUIKit:point) }
            guard let devicePoint = processor.normalizedDevicePoint(atUIKit:point) else { return }
            sessionQueue.async { [self] in
                guard let device = videoInput?.device, !configuration.aeafLock,
                      state == .ready || state == .recording else { return }
                do {
                    invalidateAI(); aiFocusHoldUntil = ProcessInfo.processInfo.systemUptime + 5
                    configuration.aiFocus = false
                    publishControlSettings()
                    try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
                    if device.isFocusPointOfInterestSupported && !configuration.manualFocus {
                        device.focusPointOfInterest = devicePoint
                        if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
                    }
                    if device.isExposurePointOfInterestSupported && !configuration.manualExposure {
                        device.exposurePointOfInterest = devicePoint
                        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                    }
                } catch { report(error.localizedDescription) }
            }
        }
    }
    func startPanorama() {
        sessionQueue.async { [self] in
            guard state == .ready, session.isRunning, configuration.mode == .panorama, let device = videoInput?.device else { return }
            guard motion.sample(at:CMClockGetTime(CMClockGetHostTimeClock()).seconds) != nil else {
                report("Motion data is not ready. Panorama needs device motion to track the sweep."); return
            }
            do { try MediaFiles.requireSpace() }
            catch { report(error.localizedDescription); return }
            let fov = Double(device.activeFormat.videoFieldOfView), settings = configuration
            setState(.recording)
            frameQueue.async { [self] in
                panorama = PanoramaAssembler(renderer:renderer,horizontalFOVDegrees:fov,feather:settings.panoramaFeather)
            }
        }
    }

    private func stopPanoramaLocked() {
        guard state == .recording, configuration.mode == .panorama else { return }
        setState(.finishing)
        let settings = configuration
        frameQueue.async { [self] in
            guard let capture = panorama else {
                sessionQueue.async { [self] in setState(wantedRunning ? .ready : .stopped) }; return
            }
            panorama = nil
            do {
                let image = try capture.finish()
                guard let encoded = CaptureMetadata.encodeProcessed(image,renderer:renderer,efficient:settings.codec == .efficient,settings:settings) else {
                    throw CameraFailure.message("The panorama could not be encoded.")
                }
                let url = try MediaFiles.newURL(extension:encoded.1)
                try encoded.0.write(to:url,options:.atomic)
                deliver(.success(MediaDraft(url:url,isVideo:false,summary:"Panorama approximation · \(capture.count) motion-guided frames")))
            } catch { deliver(.failure(error)) }
            sessionQueue.async { [self] in setState(wantedRunning ? .ready : .stopped) }
        }
    }

    func startRecording(override: CameraSettings? = nil) {
        sessionQueue.async { [self] in
            guard state == .ready, session.isRunning else { return }
            do {
                try MediaFiles.requireSpace()
                let settings = override ?? configuration
                guard settings.mode.isMovie, !settings.usesNativeMoviePipeline else {
                    throw CameraFailure.message("This recording requires the native Video capture mode.")
                }
                let url=try MediaFiles.newURL(extension:"mov")
                if override != nil {
                    recordingRestoreSettings = configuration
                    setState(.starting)
                    DispatchQueue.main.async { [weak self] in self?.onQuickTakeActive?(true) }
                    // QuickTake changes the actual session, sensor format and AI
                    // exposure bounds. A preview-only override cannot do this.
                    try configure(settings, selected: videoInput?.device.uniqueID)
                }
                let microphoneAvailable=audioInput != nil && audioOutput.connection(with:.audio) != nil
                let sourceDimensions = videoInput.map { CMVideoFormatDescriptionGetDimensions($0.device.activeFormat.formatDescription) }
                let minimumFrameTime = ProcessInfo.processInfo.systemUptime
                invalidateAI()
                setState(.recording)
                frameQueue.async { [self] in
                    do {
                        if (settings.horizonLock || settings.actionStabilization) && motion.sample(at:CMClockGetTime(CMClockGetHostTimeClock()).seconds) == nil {
                            throw CameraFailure.message("Motion data is not ready. Enable Motion permission or turn sensor-driven stabilization off.")
                        }
                        recordingMinimumFrameTime = minimumFrameTime
                        recordingSourceDimensions = sourceDimensions
                        processor.beginRecording()
                        movie=try MovieRecorder(url:url,settings:settings,renderer:renderer,microphoneAvailable:microphoneAvailable)
                        lastSpaceCheck=0
                    } catch {
                        processor.endRecording()
                        recordingSourceDimensions = nil
                        sessionQueue.async { [self] in finishMovieConfiguration() }
                        deliver(.failure(error))
                    }
                }
            } catch {
                report(error.localizedDescription)
                if recordingRestoreSettings != nil { finishMovieConfiguration() }
            }
        }
    }
    /// Session-queue-only restoration also publishes the real Photo controls.
    private func finishMovieConfiguration() {
        invalidateAI()
        if let restore = recordingRestoreSettings {
            recordingRestoreSettings = nil
            do { try configure(restore, selected: videoInput?.device.uniqueID) }
            catch {
                report("The video was finalized, but Photo mode could not be restored: \(error.localizedDescription)")
                setState(.stopped)
                DispatchQueue.main.async { [weak self] in self?.onQuickTakeActive?(false) }
                return
            }
            DispatchQueue.main.async { [weak self] in self?.onQuickTakeActive?(false) }
        }
        setState(wantedRunning && session.isRunning && !session.isInterrupted ? .ready : .stopped)
    }
    func stopRecording() { sessionQueue.async { [self] in stopRecordingLocked() } }
    private func stopRecordingLocked() {
        guard state == .recording else { return }
        if let native = session.outputs.compactMap({ $0 as? AVCaptureMovieFileOutput }).first(where: { $0.isRecording }) {
            setState(.finishing); native.stopRecording(); return
        }
        if configuration.mode == .panorama { stopPanoramaLocked(); return }
        setState(.finishing)
        frameQueue.async { [self] in
            guard let recorder = movie else {
                processor.endRecording()
                recordingSourceDimensions = nil
                sessionQueue.async { [self] in finishMovieConfiguration() }; return
            }
            movie=nil; processor.endRecording()
            recordingSourceDimensions = nil
            recorder.finish { [self] result in
                let mapped = result.map { url in MediaDraft(url:url,isVideo:true,
                    summary:"\(recorder.settings.mode.rawValue) · \(recorder.settings.resolution.rawValue) output · H:\(recorder.settings.horizonLock ? "on":"off") Z:\(recorder.settings.zoomLock ? "on":"off")") }
                deliver(mapped)
                sessionQueue.async { [self] in finishMovieConfiguration() }
            }
        }
    }
    func captureVideoStill() {
        frameQueue.async { [self] in
            guard session.isRunning, let frame=processor.preview.snapshot() else { return }
            do {
                try MediaFiles.requireSpace()
                let image = movie == nil ? frame.image : frame.recordingImage
                var stillSettings=processor.settings
                stillSettings.customMetadataEnabled=false
                stillSettings.includeLocationMetadata=false
                guard let encoded=CaptureMetadata.encodeProcessed(image,renderer:renderer,efficient:true,settings:stillSettings) else {
                    throw CameraFailure.message("Could not encode the video still.")
                }
                let url=try MediaFiles.newURL(extension:encoded.1)
                try encoded.0.write(to:url,options:.atomic)
                deliver(.success(MediaDraft(url:url,isVideo:false,summary:"Still photo captured during video · \(Int(image.extent.width))×\(Int(image.extent.height))")))
            } catch { deliver(.failure(error)) }
        }
    }

    private func plannedPhotoSteps(_ settings: CameraSettings) throws -> [PhotoCaptureStep] {
        try PhotoCapturePlanner.steps(dual: settings.dualPhotoCapture, raw: settings.raw,
            preferProRAW: settings.preferProRAW, live: settings.livePhoto,
            exactExposure: settings.exactExposure,
            supportsBayerRAW: photoOutput.availableRawPhotoPixelFormatTypes.contains(where: AVCapturePhotoOutput.isBayerRAWPixelFormat),
            supportsProRAW: photoOutput.isAppleProRAWSupported,
            supportsLive: photoOutput.isLivePhotoCaptureSupported)
    }

    func capturePhoto() {
        sessionQueue.async { [self] in
            guard state == .ready, session.isRunning, let device = videoInput?.device else { return }
            do {
                try MediaFiles.requireSpace()
                guard configuration.mode.isPhotoMode else { throw CameraFailure.message("Use Photo mode to capture a full-resolution original.") }
                let config = configuration
                let steps = try plannedPhotoSteps(config)
                let pairID: UUID? = steps.count > 1 ? UUID() : nil
                // All combinations are validated before the first half of a pair.
                for step in steps { _ = try photoSettings(for: step, config: config, device: device, createLiveFile: false) }
                photoSequenceInterrupted = false
                setState(.takingPhoto)
                try freezeFocusAndWhiteBalance(device: device)
                capturePhotoStep(steps, index: 0, config: config, pairID: pairID)
            } catch { deliver(.failure(error)); finishPhotoSequence() }
        }
    }

    private func freezeFocusAndWhiteBalance(device: AVCaptureDevice) throws {
        try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
        if configuration.aiEnabled && configuration.aiFocus && !configuration.manualFocus && device.isFocusModeSupported(.locked) {
            device.focusMode = .locked
        }
        if configuration.aiEnabled && configuration.aiWhiteBalance && !configuration.manualWhiteBalance &&
            device.isWhiteBalanceModeSupported(.locked) {
            device.setWhiteBalanceModeLocked(with: boundedWhiteBalanceGains(device.deviceWhiteBalanceGains, device: device), completionHandler: nil)
        }
    }

    private func capturePhotoStep(_ steps: [PhotoCaptureStep], index: Int, config: CameraSettings, pairID: UUID?) {
        guard state == .takingPhoto, !photoSequenceInterrupted, wantedRunning, session.isRunning,
              !session.isInterrupted, let device = videoInput?.device else {
            deliver(.failure(CameraFailure.message("The photo sequence was interrupted. Any completed original remains saved.")))
            finishPhotoSequence(); return
        }
        do {
            let step = steps[index]
            let settings = try photoSettings(for: step, config: config, device: device, createLiveFile: true)
            let id = settings.uniqueID
            let codec: AVVideoCodecType = config.codec == .efficient ? .hevc : .jpeg
            let delegate = PhotoCapture(id: id, settings: config, step: step, liveURL: settings.livePhotoMovieFileURL,
                processedFileExtension: codec == .jpeg ? "jpg" : "heic", pairID: pairID) { [weak self] result in
                guard let self else { return }
                self.frameQueue.async { [self] in
                    do {
                        let packet = try result.get()
                        let saved = try savePhoto(packet)
                        for draft in saved.drafts { deliver(.success(draft)) }
                        if let warning = saved.warning {
                            deliver(.failure(CameraFailure.message("Partial capture: completed originals were saved. \(warning)")))
                        }
                        sessionQueue.async { [self] in
                            photoJobs.removeValue(forKey: id)
                            let requiredRAWExists = steps[index].rawKind == .none || saved.rawSaved
                            if requiredRAWExists && index + 1 < steps.count { capturePhotoStep(steps, index: index + 1, config: config, pairID: pairID) }
                            else { finishPhotoSequence() }
                        }
                    } catch {
                        let message = index > 0 ? "The RAW master was saved, but its Live companion failed: \(error.localizedDescription)" : error.localizedDescription
                        deliver(.failure(CameraFailure.message(message)))
                        sessionQueue.async { [self] in photoJobs.removeValue(forKey: id); finishPhotoSequence() }
                    }
                }
            }
            photoJobs[id] = delegate
            photoOutput.capturePhoto(with: settings, delegate: delegate)
        } catch {
            deliver(.failure(CameraFailure.message(index > 0 ? "The RAW master was saved, but its Live companion failed: \(error.localizedDescription)" : error.localizedDescription)))
            finishPhotoSequence()
        }
    }

    private func finishPhotoSequence() {
        if let device = videoInput?.device { try? applyControls(configuration, device: device) }
        invalidateAI()
        setState(wantedRunning && session.isRunning && !session.isInterrupted ? .ready : .stopped)
    }

    private func photoSettings(for step: PhotoCaptureStep, config: CameraSettings,
                               device: AVCaptureDevice, createLiveFile: Bool) throws -> AVCapturePhotoSettings {
        if step.rawKind == .bayer {
            guard let connection = photoOutput.connection(with: .video) else {
                throw CameraFailure.message("The photo output is not connected to the selected camera.")
            }
            // Validate actual hardware/connection values, including an unfinished
            // zoom ramp, before AVFoundation can reject this request by exception.
            try PhotoCapturePlanner.validateRAWZoom(rawKind: step.rawKind,
                deviceZoomFactor: Double(device.videoZoomFactor),
                connectionScaleAndCropFactor: Double(connection.videoScaleAndCropFactor),
                isZoomRamping: device.isRampingVideoZoom)
        }
        let codec: AVVideoCodecType = config.codec == .efficient ? .hevc : .jpeg
        guard photoOutput.availablePhotoCodecTypes.contains(codec) else {
            throw CameraFailure.message("The requested \(codec == .hevc ? "HEIF" : "JPEG") format is unavailable. Select an available format.")
        }
        let processed: [String: Any] = [AVVideoCodecKey: codec, AVVideoQualityKey: 1.0]
        let settings: AVCapturePhotoSettings
        if step.rawKind != .none {
            let raw = photoOutput.availableRawPhotoPixelFormatTypes.first {
                step.rawKind == .appleProRAW ? AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) : AVCapturePhotoOutput.isBayerRAWPixelFormat($0)
            }
            guard let raw else { throw CameraFailure.message("The requested RAW format is not enabled for this capture configuration.") }
            settings = AVCapturePhotoSettings(rawPixelFormatType: raw, processedFormat: processed)
        } else { settings = AVCapturePhotoSettings(format: processed) }
        let requestedPriority: PhotoCapturePriority
        switch config.photoQuality {
        case .speed: requestedPriority = .speed
        case .balanced: requestedPriority = .balanced
        case .quality: requestedPriority = .quality
        }
        let priority = PhotoCapturePlanner.effectivePriority(for: step, requested: requestedPriority)
        switch priority {
        case .speed: settings.photoQualityPrioritization = .speed
        case .balanced: settings.photoQualityPrioritization = .balanced
        case .quality: settings.photoQualityPrioritization = .quality
        }
        let supported = device.activeFormat.supportedMaxPhotoDimensions.filter {
            Int64($0.width) * Int64($0.height) <= Int64(photoOutput.maxPhotoDimensions.width) * Int64(photoOutput.maxPhotoDimensions.height)
        }
        func megapixels(_ dimensions: CMVideoDimensions) -> Double {
            Double(dimensions.width) * Double(dimensions.height) / 1_000_000
        }
        let available = supported.filter {
            PhotoCapturePlanner.supportsResolution(megapixels: megapixels($0), priority: priority)
        }
        if !step.maximumResolution && config.photoResolutionMP > 0 {
            guard let dimensions = supported.first(where: { Int(megapixels($0).rounded()) == config.photoResolutionMP }) else {
                throw CameraFailure.message("\(config.photoResolutionMP) MP is unavailable on the selected lens and format.")
            }
            guard PhotoCapturePlanner.supportsResolution(megapixels: megapixels(dimensions), priority: priority) else {
                throw CameraFailure.message("\(config.photoResolutionMP) MP is incompatible with \(priority.rawValue) priority. Speed supports the 12 MP family; 18/24 MP require Quality; 48 MP requires Balanced or Quality. Choose a compatible resolution or priority.")
            }
            settings.maxPhotoDimensions = dimensions
        } else {
            guard let dimensions = available.max(by: { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) }) else {
                throw CameraFailure.message("No photo dimensions support \(priority.rawValue) priority on the selected lens. Choose Quality or another lens.")
            }
            settings.maxPhotoDimensions = dimensions
        }
        settings.metadata = CaptureMetadata.photo(config)
        let hasRAW = step.rawKind != .none
        settings.isAutoRedEyeReductionEnabled = !hasRAW && config.autoRedEyeReduction && photoOutput.isAutoRedEyeReductionSupported
        settings.isAutoContentAwareDistortionCorrectionEnabled = !hasRAW && config.contentAwareDistortionCorrection && photoOutput.isContentAwareDistortionCorrectionEnabled
        settings.isAutoVirtualDeviceFusionEnabled = !hasRAW && !step.exactExposure && config.virtualDeviceFusion && photoOutput.isVirtualDeviceFusionSupported
        settings.isCameraCalibrationDataDeliveryEnabled = !hasRAW && config.cameraCalibrationData && photoOutput.isCameraCalibrationDataDeliverySupported
        settings.isDepthDataDeliveryEnabled = !hasRAW && config.depthData && photoOutput.isDepthDataDeliveryEnabled
        settings.embedsDepthDataInPhoto = settings.isDepthDataDeliveryEnabled
        settings.isDepthDataFiltered = config.depthDataFiltered
        settings.isPortraitEffectsMatteDeliveryEnabled = !hasRAW && config.portraitEffectsMatte && photoOutput.isPortraitEffectsMatteDeliveryEnabled
        settings.embedsPortraitEffectsMatteInPhoto = settings.isPortraitEffectsMatteDeliveryEnabled
        settings.enabledSemanticSegmentationMatteTypes = !hasRAW && config.semanticMattes ? photoOutput.enabledSemanticSegmentationMatteTypes : []
        settings.embedsSemanticSegmentationMattesInPhoto = !settings.enabledSemanticSegmentationMatteTypes.isEmpty
        if photoOutput.isStillImageStabilizationSupported && step.exactExposure { settings.isAutoStillImageStabilizationEnabled = false }
        if #available(iOS 18.0, *) {
            settings.isConstantColorEnabled = !hasRAW && !step.exactExposure && config.constantColor && photoOutput.isConstantColorEnabled
            settings.isConstantColorFallbackPhotoDeliveryEnabled = settings.isConstantColorEnabled && config.constantColorFallback
        }
        if photoOutput.supportedFlashModes.contains(config.flash.avMode) { settings.flashMode = config.flash.avMode }
        else if config.flash != .off { throw CameraFailure.message("The selected flash mode is unavailable for this lens.") }
        if step.live {
            guard photoOutput.isLivePhotoCaptureEnabled, !photoOutput.isLivePhotoCaptureSuspended else {
                throw CameraFailure.message("Live Photo capture is not ready in the current session. No still-only substitute was taken.")
            }
            if createLiveFile {
                settings.livePhotoMovieFileURL = try MediaFiles.newURL(extension: "mov")
                settings.livePhotoMovieMetadata = NativeMovieController.movieMetadata(config)
                if photoOutput.availableLivePhotoVideoCodecTypes.contains(.hevc) { settings.livePhotoVideoCodecType = .hevc }
            }
        }
        return settings
    }

    struct SavedPhotoResources {
        let drafts: [MediaDraft]
        let rawSaved: Bool
        let warning: String?
    }
    func savePhoto(_ packet: PhotoPacket) throws -> SavedPhotoResources {
        // Save exactly the encoder's resources. Never decode, re-encode, crop,
        // recolor, sharpen, fuse or run a generative model on a photo original.
        var failures = [packet.warning].compactMap { $0 }
        var rawURL: URL?, processedURL: URL?
        if let raw = packet.rawData {
            do {
                let destination = try MediaFiles.newURL(extension: "dng")
                try raw.write(to: destination, options: .atomic)
                rawURL = destination
            } catch { failures.append("RAW save failed: \(error.localizedDescription)") }
        }
        if let processed = packet.data {
            do {
                let destination = try MediaFiles.newURL(extension: packet.processedFileExtension)
                try processed.write(to: destination, options: .atomic)
                processedURL = destination
            } catch { failures.append("Processed companion save failed: \(error.localizedDescription)") }
        }
        func size(_ value: CMVideoDimensions) -> String {
            String(format: "%.1f MP (%d×%d)", Double(value.width) * Double(value.height) / 1_000_000, value.width, value.height)
        }
        let complete = failures.isEmpty
        var details = [complete ? packet.step.label : "Partial original capture"]
        if processedURL != nil { details.append(size(packet.dimensions)) }
        if rawURL != nil { details.append("RAW " + size(packet.rawDimensions)); details.append("lossless DNG") }
        if packet.pairID != nil { details.append("sequential pair") }
        details.append(packet.step.exactExposure ? "Exact exposure" : "Apple capture quality")
        if packet.hasDepthData { details.append("depth metadata") }
        if packet.hasPortraitEffectsMatte { details.append("portrait matte metadata") }
        if packet.hasCalibrationData { details.append("camera calibration") }
        var drafts: [MediaDraft] = []
        if let processedURL {
            drafts.append(MediaDraft(url: processedURL, liveMovie: packet.liveMovie, raw: rawURL,
                summary: details.joined(separator: " · "), created: packet.captureDate, pairID: packet.pairID))
        } else {
            if let rawURL {
                drafts.append(MediaDraft(url: rawURL, summary: details.joined(separator: " · "),
                    created: packet.captureDate, pairID: packet.pairID))
            }
            if let liveMovie = packet.liveMovie {
                // A motion file without its photo is a recoverable video resource,
                // never a fabricated or falsely labelled Live Photo.
                drafts.append(MediaDraft(url: liveMovie, isVideo: true,
                    summary: "Partial capture · original motion resource · photo missing",
                    created: packet.captureDate, pairID: packet.pairID))
            }
        }
        guard !drafts.isEmpty else {
            throw CameraFailure.message(failures.isEmpty ? "No original resource could be saved." : failures.joined(separator: " "))
        }
        return SavedPhotoResources(drafts: drafts, rawSaved: rawURL != nil,
            warning: failures.isEmpty ? nil : failures.joined(separator: " "))
    }

    private func hostTime(for pts: CMTime) -> Double {
        guard pts.isValid && !pts.isIndefinite else { return CMClockGetTime(CMClockGetHostTimeClock()).seconds }
        if let clock = session.synchronizationClock {
            return CMSyncConvertTime(pts,from:clock,to:CMClockGetHostTimeClock()).seconds
        }
        return pts.seconds
    }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard processor.settings.scanQRCodes else { return }
        for object in metadataObjects {
            if let code = object as? AVMetadataMachineReadableCodeObject, code.type == .qr,
               let value = code.stringValue, !value.isEmpty {
                DispatchQueue.main.async { [weak self] in self?.onCode?(value) }
                break
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === audioOutput {
            do { try movie?.appendAudio(sampleBuffer) }
            catch { report(error.localizedDescription); stopRecording() }
            return
        }
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer), now = hostTime(for:pts)
        if now - lastAITime >= 0.25 {
            lastAITime = now
            aiHandoffLock.lock()
            let canSchedule = !aiHandoffPending
            if canSchedule { aiHandoffPending = true }
            aiHandoffLock.unlock()
            if canSchedule {
                sessionQueue.async { [weak self] in
                    guard let self else { return }
                    defer {
                        self.aiHandoffLock.lock(); self.aiHandoffPending = false; self.aiHandoffLock.unlock()
                    }
                    guard self.state == .ready || self.state == .recording,
                          now >= self.aiMinimumFrameTime, let device = self.videoInput?.device,
                          !device.isRampingVideoZoom else { return }
                    let telemetry = self.cameraTelemetry(device: device)
                    if now - self.lastTelemetryTime >= 0.5 {
                        self.lastTelemetryTime = now
                        DispatchQueue.main.async { [weak self] in self?.onTelemetry?(telemetry) }
                    }
                    if self.configuration.aiEnabled {
                        self.intelligence.analyze(pixelBuffer: buffer, timestamp: now,
                            settings: self.configuration, telemetry: telemetry)
                    }
                }
            }
        }
        if processor.settings.showDetectedText && now-lastTextTime >= 0.75 {
            lastTextTime = now
            let retained = buffer
            textQueue.async { [weak self] in
                guard let self else { return }
                let lines = self.textDetector.recognize(retained)
                DispatchQueue.main.async { [weak self] in self?.onText?(lines) }
            }
        }
        if #available(iOS 26.0, *), processor.settings.smartFraming && now-lastSmartFramingTime >= 0.35 {
            lastSmartFramingTime = now
            NativeMovieController.applySmartFramingIfNeeded(processor.settings,engine:self)
        }
        autoreleasepool {
            do {
                let frame = try processor.process(buffer:buffer,hostTime:now)
                if let panorama, let reading = motion.sample(at:now) { panorama.append(frame.overview,yaw:reading.yaw) }
                if let movie {
                    // Drop stale Photo-mode buffers during QuickTake's real format
                    // transition; never upscale those into a claimed 4K video.
                    let deliveredLong = max(CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer))
                    let deliveredShort = min(CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer))
                    let expected = recordingSourceDimensions
                    let matchesFormat = expected.map { deliveredLong == Int(max($0.width, $0.height)) && deliveredShort == Int(min($0.width, $0.height)) } ?? true
                    if now >= recordingMinimumFrameTime && matchesFormat {
                        try movie.appendVideo(frame.recordingImage,sourcePTS:pts)
                    } else if movie.writtenFrames == 0 && now - recordingMinimumFrameTime > 3 {
                        throw CameraFailure.message("The requested video sensor format did not become ready. No lower-resolution substitute was recorded.")
                    }
                }
                if movie != nil && now-lastSpaceCheck > 5 {
                    lastSpaceCheck = now; try MediaFiles.requireSpace()
                }
                if now-lastDiagnosticsTime > 0.1 {
                    lastDiagnosticsTime = now
                    var info = frame.diagnostics
                    info.recordingSeconds = movie?.duration ?? 0
                    info.droppedFrames += movie?.droppedFrames ?? 0
                    if #available(iOS 26.0, *), let device = frameDevice, device.activeFormat.isCameraLensSmudgeDetectionSupported {
                        switch device.cameraLensSmudgeDetectionStatus {
                        case .smudged: info.lensStatus = "Clean lens"
                        case .smudgeNotDetected: info.lensStatus = "Clear"
                        case .unknown: info.lensStatus = processor.settings.lensCleaningHints ? "Checking" : "Off"
                        case .disabled: info.lensStatus = "Off"
                        @unknown default: info.lensStatus = "Unknown"
                        }
                    }
                    if #available(iOS 26.0, *), processor.settings.smartFraming {
                        info.smartFramingStatus = frameDevice?.smartFramingMonitor?.recommendedFraming == nil ? "Monitoring" : "Recommended"
                    }
                    DispatchQueue.main.async { [weak self] in self?.onDiagnostics?(info) }
                }
            } catch { report(error.localizedDescription); stopRecording() }
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput { processor.dropped += 1 }
    }
}

@available(iOS 18.0, *)
extension CaptureEngine: AVCaptureSessionControlsDelegate {
    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {}
    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {}
    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {}
    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {}
}
