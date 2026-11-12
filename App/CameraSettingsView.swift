import SwiftUI

enum ControlAuthority: String, CaseIterable, Identifiable {
    case ai = "AI", camera = "Camera", manual = "Manual"
    var id: String { rawValue }
}

struct CameraSettingsView: View {
    @ObservedObject var model: CameraModel
    @Environment(\.dismiss) private var dismiss
    @State private var diagnosticFile: URL?
    @State private var category = "Capture"
    init(model: CameraModel, category: String = "Capture") {
        self.model = model
        _category = State(initialValue: category)
    }
    private let categories = ["Capture", "AI", "Manual", "Video", "Guides", "Metadata"]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(categories, id: \.self) { value in
                            Button(value) { category = value }
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .background(category == value ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08), in: Capsule())
                        }
                    }.padding(.horizontal).padding(.vertical, 8)
                }
                Form {
                    switch category {
                    case "AI": intelligenceSection; intelligenceDetails
                    case "Manual": exposureSection; focusSection; whiteBalanceSection; apertureSection
                    case "Video": videoSection; audioSection; stabilizationSection
                    case "Guides": viewfinderSection; opticsSection; calibrationSection
                    case "Metadata": metadataSection; savingSection; aboutSection
                    default: captureSection; photoOptionsSection
                    }
                }.disabled(!model.canAdjustControls || (model.isRecording && ["Capture", "Video", "Metadata"].contains(category)))
            }
            .navigationTitle("TrueCamera")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { model.persist(); dismiss() } } }
        }.tint(.accentColor)
    }

    private var captureSection: some View {
        Section("Original photo capture") {
            Toggle("Dual: maximum RAW + Live Photo", isOn: model.binding(\.dualPhotoCapture))
            Text("One shutter, two consecutive exposures. Saves a lossless RAW master with its standard companion, then a separate full-quality Live Photo. Moving subjects can differ between the two.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("RAW master", selection: model.binding(\.preferProRAW)) {
                Text("Apple ProRAW · maximum detail").tag(true).disabled(!model.capabilities.proRAW)
                Text("Bayer RAW · sensor mosaic").tag(false).disabled(!model.capabilities.bayerRAW)
            }
            Text(model.settings.preferProRAW
                 ? "ProRAW includes Apple's computational processing. TrueCamera requests lossless DNG at the maximum available bit depth and resolution; it adds no image look."
                 : "Bayer RAW retains the minimally processed sensor mosaic. Its maximum resolution may be lower than ProRAW on the same camera.")
                .font(.caption).foregroundStyle(.secondary)
            if let reason = model.capabilities.photoCaptureReason {
                Label(reason, systemImage: "info.circle").font(.caption).foregroundStyle(.orange)
            }
            if !model.settings.dualPhotoCapture {
                Toggle("Save RAW master", isOn: model.binding(\.raw))
                    .disabled(!model.capabilities.raw && !model.capabilities.proRAW)
                Toggle("Live Photo", isOn: model.binding(\.livePhoto))
                    .disabled(!model.capabilities.livePhoto || (model.settings.raw && model.settings.preferProRAW))
                Picker("Maximum resolution", selection: model.binding(\.photoResolutionMP)) {
                    Text("Largest available").tag(0)
                    ForEach(model.capabilities.supportedPhotoResolutionsMP, id: \.self) { mp in
                        let reason = model.photoResolutionUnavailableReason(mp)
                        Text(reason.map { "\(mp) MP · \($0)" } ?? "\(mp) MP").tag(mp).disabled(reason != nil)
                    }
                }
                Picker("Processing priority", selection: Binding(get: {
                    PhotoQualityChoice(rawValue: model.photoCapturePriority.rawValue) ?? .quality
                }, set: { value in model.change { $0.photoQuality = value } })) {
                    ForEach(PhotoQualityChoice.allCases) { Text($0.rawValue).tag($0) }
                }.disabled(model.settings.exactExposure || (model.settings.raw && !model.settings.preferProRAW))
                if model.settings.photoResolutionMP > 0,
                   let reason = model.photoResolutionUnavailableReason(model.settings.photoResolutionMP) {
                    Text("\(reason). Select Largest available or a compatible resolution.").font(.caption).foregroundStyle(.orange)
                }
            }
            Picker("Standard photo", selection: model.binding(\.codec)) {
                Text("HEIF · maximum quality").tag(CodecChoice.efficient)
                Text("JPEG · maximum quality").tag(CodecChoice.compatible)
            }
            Toggle("Exact ISO / shutter", isOn: model.binding(\.exactExposure))
                .disabled(model.settings.dualPhotoCapture && !model.settings.exactExposure)
            Text("Exact exposure uses Apple's speed-priority capture to honor selected sensor settings. Maximum-quality processing may adjust exposure and supports larger resolutions. Maximum dual capture requires Exact exposure off.")
                .font(.caption).foregroundStyle(.secondary)
            Text("RAW and Live originals are never cropped, recolored or passed through TrueCamera's stabilization renderer. Actual delivered resolution, time and exposure are shown with each capture.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var photoOptionsSection: some View {
        Section("Capture options") {
            Picker("Flash", selection: model.binding(\.flash)) { ForEach(FlashChoice.allCases) { Text($0.rawValue).tag($0) } }
                .disabled(!model.capabilities.flash)
            Picker("Timer", selection: model.binding(\.timer)) { ForEach([0, 3, 5, 10], id: \.self) { Text($0 == 0 ? "Off" : "\($0) seconds").tag($0) } }
            Toggle("Responsive capture", isOn: model.binding(\.responsiveCapture)).disabled(!model.capabilities.responsiveCapture)
            Toggle("Zero shutter lag", isOn: model.binding(\.zeroShutterLag)).disabled(!model.capabilities.zeroShutterLag)
            Toggle("Embed depth data", isOn: model.binding(\.depthData))
                .disabled(!model.capabilities.depthData || model.settings.raw || model.settings.dualPhotoCapture)
            if model.settings.depthData {
                Toggle("Filtered depth map", isOn: model.binding(\.depthDataFiltered))
                Toggle("Embed subject matte", isOn: model.binding(\.portraitEffectsMatte)).disabled(!model.capabilities.portraitEffectsMatte)
            }
            Toggle("Embed semantic mattes", isOn: model.binding(\.semanticMattes))
                .disabled(!model.capabilities.semanticMattes || model.settings.raw || model.settings.dualPhotoCapture)
            Toggle("Embed camera calibration", isOn: model.binding(\.cameraCalibrationData))
                .disabled(!model.capabilities.cameraCalibrationData || model.settings.raw || model.settings.dualPhotoCapture)
            Text("Depth and mattes are auxiliary data only. They do not blur, relight or replace anything in your photo.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var intelligenceSection: some View {
        Section("On-device intelligence") {
            Toggle("AI camera control", isOn: model.binding(\.aiEnabled))
            Toggle("Exposure and motion control", isOn: model.binding(\.aiExposure)).disabled(!model.settings.aiEnabled)
            Toggle("Subject-aware focus", isOn: model.binding(\.aiFocus)).disabled(!model.settings.aiEnabled)
            Toggle("White-balance stability", isOn: model.binding(\.aiWhiteBalance)).disabled(!model.settings.aiEnabled)
            Toggle("Physical aperture", isOn: model.binding(\.aiAperture))
                .disabled(!model.settings.aiEnabled || !model.capabilities.supportsManualAperture)
            Toggle("Show AI decisions", isOn: model.binding(\.showAIStatus))
            Text("Apple's trained Vision networks analyze scene content, attention and faces. A bounded camera controller combines that inference with measured light and motion to select real capture controls. Manual choices always take ownership of that control.")
                .font(.caption).foregroundStyle(.secondary)
            Text("AI runs locally, with no account, key or image upload. It does not generate pixels, apply styles, beautify skin or invent detail. It is not a guarantee of objectively perfect color or the best exposure in every scene.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var intelligenceDetails: some View {
        Section("Live AI analysis") {
            LabeledContent("State", value: model.aiStatus.state.rawValue.capitalized)
            LabeledContent("Scene", value: model.aiStatus.scene)
            LabeledContent("Confidence", value: String(format: "%.0f%%", model.aiStatus.confidence * 100))
            Text(model.aiStatus.reason).font(.callout)
            LabeledContent("Inference", value: String(format: "%.0f ms · %.1f / second", model.aiStatus.latencyMS, model.aiStatus.analysesPerSecond))
            LabeledContent("Frames analyzed", value: "\(model.aiStatus.framesAnalyzed)")
            Text(model.aiStatus.modelSummary).font(.caption).foregroundStyle(.secondary)
            Text("These are scene-model confidence values, not a photo-quality score. The normal preview is Apple's processed preview; the sensor RAW file remains separate.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func authority(_ title: String, ai: WritableKeyPath<CameraSettings, Bool>, manual: WritableKeyPath<CameraSettings, Bool>) -> some View {
        Picker(title, selection: Binding<ControlAuthority>(get: {
            if model.settings[keyPath: manual] { return .manual }
            return model.settings.aiEnabled && model.settings[keyPath: ai] ? .ai : .camera
        }, set: { owner in
            model.change {
                $0[keyPath: ai] = owner == .ai
                $0[keyPath: manual] = owner == .manual
                if owner == .ai { $0.aiEnabled = true }
                if ai == \.aiWhiteBalance { $0.whiteBalanceLock = false }
            }
        })) { ForEach(ControlAuthority.allCases) { Text($0.rawValue).tag($0) } }
            .pickerStyle(.segmented)
    }
    private var exposureSection: some View {
        Section("Exposure · real sensor controls") {
            authority("Exposure control", ai: \.aiExposure, manual: \.manualExposure)
            LabeledContent("Exposure compensation", value: String(format: "%+.1f EV", model.settings.exposureEV))
            Slider(value: model.binding(\.exposureEV), in: model.capabilities.minEV...max(model.capabilities.minEV + 0.1, model.capabilities.maxEV), step: 0.1)
                .disabled(model.settings.manualExposure || model.settings.aeafLock)
            if model.settings.manualExposure {
                LabeledContent("ISO", value: String(format: "%.0f", model.settings.iso))
                Slider(value: model.binding(\.iso), in: model.capabilities.minISO...max(model.capabilities.minISO + 1, model.capabilities.maxISO), step: 1)
                if model.settings.mode.isMovie { Toggle("Shutter angle", isOn: model.binding(\.shutterAngleMode)) }
                if model.settings.shutterAngleMode && model.settings.mode.isMovie {
                    LabeledContent("Angle", value: String(format: "%.1f°", model.settings.shutterAngle))
                    Slider(value: model.binding(\.shutterAngle), in: 1.1...360, step: 0.1)
                } else {
                    LabeledContent("Shutter", value: shutterLabel(1 / max(0.001, model.settings.shutterDenominator)))
                    Slider(value: Binding(get: { log2(1 / max(0.001, model.settings.shutterDenominator)) }, set: { value in model.change { $0.shutterDenominator = 1 / pow(2, value) } }), in: shutterRange)
                }
            }
            Toggle("AE / AF lock", isOn: model.binding(\.aeafLock))
            LabeledContent("Current aperture", value: model.capabilities.currentAperture > 0 ? String(format: "f/%.2f", model.capabilities.currentAperture) : "Reported when camera starts")
            Text("Still exposure uses the lens's actual exposure range. Video exposure is constrained by the selected frame duration. Exact exposure is selected under Capture.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var shutterRange: ClosedRange<Double> {
        let low = max(0.000001, model.capabilities.minShutterSeconds)
        let high = max(low * 1.01, model.capabilities.maxShutterSeconds)
        return log2(low)...log2(high)
    }
    private func shutterLabel(_ seconds: Double) -> String {
        seconds >= 1 ? String(format: "%.2f s", seconds) : String(format: "1/%.0f s", 1 / max(0.000001, seconds))
    }
    private var focusSection: some View {
        Section("Focus") {
            authority("Focus control", ai: \.aiFocus, manual: \.manualFocus).disabled(!model.capabilities.manualFocus)
            if model.settings.manualFocus {
                LabeledContent("Lens position", value: String(format: "%.3f", model.settings.lensPosition))
                Slider(value: model.binding(\.lensPosition), in: 0...1)
                HStack { Text("Near"); Spacer(); Text("Far") }.font(.caption).foregroundStyle(.secondary)
            } else {
                Toggle("Smooth autofocus", isOn: model.binding(\.smoothAutofocus)).disabled(!model.capabilities.smoothAutofocus || model.isRecording)
                Toggle("Face-driven autofocus", isOn: model.binding(\.faceDrivenAutofocus)).disabled(!model.capabilities.faceDrivenAutofocus || model.isRecording)
                Picker("Focus range", selection: model.binding(\.focusRange)) { ForEach(FocusRangeChoice.allCases) { Text($0.rawValue).tag($0) } }
                    .disabled(!model.capabilities.focusRangeRestriction || model.isRecording)
            }
            Text("Tap the image to place focus and take focus control from AI. Re-enable AI Focus to return it. Hold the image for AE/AF Lock.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var whiteBalanceSection: some View {
        Section("White balance") {
            authority("White-balance control", ai: \.aiWhiteBalance, manual: \.manualWhiteBalance)
            if model.settings.manualWhiteBalance {
                LabeledContent("Temperature", value: "\(Int(model.settings.whiteBalanceKelvin)) K")
                Slider(value: model.binding(\.whiteBalanceKelvin), in: 2500...10000, step: 25)
                LabeledContent("Tint", value: String(format: "%+.0f", model.settings.whiteBalanceTint))
                Slider(value: model.binding(\.whiteBalanceTint), in: -150...150, step: 1)
            }
            Toggle("Hold current white balance", isOn: model.binding(\.whiteBalanceLock))
            Text("AI stabilizes the camera's measured white balance; it does not impose warm/cool looks. Use a neutral reference under the scene's light when exact color matching matters.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var apertureSection: some View {
        Section("Physical aperture") {
            if model.capabilities.supportsManualAperture {
                authority("Aperture control", ai: \.aiAperture, manual: \.manualAperture)
                if model.settings.manualAperture {
                    LabeledContent("Aperture", value: String(format: "f/%.2f", model.settings.aperture))
                    Slider(value: model.binding(\.aperture), in: model.capabilities.minAperture...max(model.capabilities.minAperture + 0.01, model.capabilities.maxAperture), step: 0.05)
                }
            } else {
                Text("This active camera/build does not report a controllable aperture. Its measured f-number is shown under Exposure.")
            }
            Text("Only real aperture control is exposed on supported hardware and iOS. No simulated depth-of-field or portrait-blur slider.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var videoSection: some View {
        Section("Video formats") {
            if !model.settings.mode.isMovie { Text("Select a video mode on the camera screen to configure recording.").font(.caption) }
            Picker("Resolution", selection: model.binding(\.resolution)) {
                ForEach(Resolution.allCases) { Text($0.rawValue).tag($0).disabled(!model.resolutionAvailable($0)) }
            }.disabled(!model.settings.mode.isMovie)
            Picker("Frames / second", selection: model.binding(\.fps)) {
                ForEach(FrameRateCatalog.all, id: \.self) { Text(FrameRateCatalog.label($0)).tag($0).disabled(!model.frameRateAvailable($0)) }
            }.disabled(model.settings.mode != .video)
            Picker("Slow-motion capture", selection: model.binding(\.slowMotionFPS)) {
                ForEach([120, 240], id: \.self) { Text("\($0) fps").tag($0).disabled(!model.capabilities.supportedSlowMotionFPS.contains($0)) }
            }.disabled(model.settings.mode != .slowMotion)
            Picker("Encoding", selection: model.binding(\.codec)) {
                ForEach(CodecChoice.allCases) { Text($0.rawValue).tag($0).disabled(!model.codecAvailable($0)) }
            }.disabled(!model.settings.mode.isMovie)
            Picker("Color encoding", selection: model.binding(\.colorProfile)) {
                ForEach(VideoColorProfile.allCases) { Text($0.rawValue).tag($0).disabled(!model.colorProfileAvailable($0)) }
            }.disabled(!model.settings.mode.isMovie)
            Toggle("Lock physical camera", isOn: model.binding(\.lockCameraSwitching)).disabled(!model.capabilities.lockCameraSwitching)
            Toggle("Camera low-light Auto FPS", isOn: model.binding(\.autoFPS)).disabled(!model.capabilities.autoFPS)
            Picker("Time-lapse interval", selection: model.binding(\.timeLapseInterval)) {
                ForEach([0.5, 1.0, 2.0, 5.0, 10.0], id: \.self) { Text(String(format: "%g seconds", $0)).tag($0) }
            }.disabled(model.settings.mode != .timeLapse)
            Text("120/240 fps in VIDEO plays at real speed; SLO-MO is retimed. Log is a recording encoding for a color-managed workflow, not a cinematic filter. Native HDR/Log/ProRes paths keep their native precision and disable incompatible custom geometric stabilization.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var stabilizationSection: some View {
        Section("Stabilization") {
            Toggle("Horizon Lock", isOn: model.binding(\.horizonLock)).disabled(!geometryAvailable)
            Toggle("Floating Zoom Lock", isOn: model.binding(\.zoomLock)).disabled(!geometryAvailable)
            Toggle("Action", isOn: model.binding(\.actionStabilization)).disabled(model.settings.mode != .video || !geometryAvailable || model.settings.fps > 60)
            Toggle("Smart motion correction", isOn: model.binding(\.smartArtifactGuard)).disabled(!geometryAvailable)
            Toggle("Native assist for Action", isOn: model.binding(\.actionNativeAssist))
                .disabled(!model.canConfigure || !model.settings.actionStabilization || model.settings.horizonLock || model.settings.zoomLock || !model.capabilities.supportedStabilizationModes.contains(where: { $0 != .off && $0 != .auto }))
            Picker("Native stabilization", selection: model.binding(\.stabilization)) {
                ForEach(model.capabilities.supportedStabilizationModes.filter { $0 != .auto }) { Text($0.rawValue).tag($0) }
            }.disabled(!model.canConfigure || !model.settings.mode.isMovie || model.settings.actionStabilization || model.settings.horizonLock || model.settings.zoomLock)
            Button("Reset framing") { model.resetFraming() }
            Text("Horizon Lock uses gravity to keep video level. Floating Zoom Lock holds framing within the available image, while Action and Smart correction stabilize recorded video. Stabilization can reduce field of view and effective resolution. Photo originals keep their native framing.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var geometryAvailable: Bool { model.settings.mode.isMovie && !model.settings.usesNativeMoviePipeline }
    private var audioSection: some View {
        Section("Audio") {
            Toggle("Microphone", isOn: Binding(get: { model.settings.audio }, set: { model.enableAudio($0) }))
            Picker("Channels", selection: model.binding(\.audioMode)) {
                Text("Mono").tag(AudioCaptureMode.mono)
                Text("Stereo").tag(AudioCaptureMode.stereo).disabled(!model.capabilities.stereoAudio)
                Text("Spatial / Ambisonic").tag(AudioCaptureMode.spatial).disabled(!model.capabilities.spatialAudio)
            }
            Toggle("Wind-noise removal", isOn: model.binding(\.windNoiseRemoval)).disabled(!model.capabilities.windNoiseRemoval)
        }
    }
    private var viewfinderSection: some View {
        Section("Viewfinder guides · never saved into images") {
            Toggle("Histogram", isOn: model.binding(\.showHistogram))
            Toggle("Highlight clipping stripes", isOn: model.binding(\.showZebras))
            Toggle("Focus peaking", isOn: model.binding(\.showFocusPeaking))
            Toggle("Grid", isOn: model.binding(\.grid))
            Toggle("Level", isOn: model.binding(\.showLevel))
            Toggle("Full-lens mini overview", isOn: model.binding(\.showOverview))
            Toggle("Frame statistics", isOn: model.binding(\.showStats))
            Toggle("Live Text", isOn: model.binding(\.showDetectedText))
            Toggle("QR detection", isOn: model.binding(\.scanQRCodes)).disabled(!model.capabilities.qrScanning)
            Toggle("Mirror front camera", isOn: model.binding(\.mirrorSelfie))
        }
    }
    private var opticsSection: some View {
        Section("Native optics") {
            Toggle("Lens distortion correction", isOn: model.binding(\.contentAwareDistortionCorrection)).disabled(!model.capabilities.contentAwareDistortionCorrection || model.settings.raw || model.settings.dualPhotoCapture)
            Toggle("Apple virtual-camera fusion", isOn: model.binding(\.virtualDeviceFusion)).disabled(!model.capabilities.virtualDeviceFusion)
            Toggle("Sensor orientation compensation", isOn: model.binding(\.sensorOrientationCompensation)).disabled(!model.capabilities.sensorOrientationCompensation || model.settings.raw)
            Toggle("Lens-cleaning hints", isOn: model.binding(\.lensCleaningHints)).disabled(!model.capabilities.lensSmudgeDetection || model.isRecording)
            Text("These are the camera's public native controls. Bayer RAW and Apple ProRAW remain different capture pipelines; disabling an optional switch cannot remove all Apple ISP processing from processed images.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var calibrationSection: some View {
        Section("Calibration and diagnostics") {
            LabeledContent("Horizon trim", value: String(format: "%+.1f°", model.settings.horizonTrimDegrees))
            Slider(value: model.binding(\.horizonTrimDegrees), in: -10...10, step: 0.1)
            LabeledContent("Motion timing offset", value: String(format: "%+.0f ms", model.settings.motionOffsetMilliseconds))
            Slider(value: model.binding(\.motionOffsetMilliseconds), in: -50...50, step: 1)
            LabeledContent("Capture source", value: model.capabilities.sourceDescription)
            LabeledContent("Frame rate", value: String(format: "%.1f fps", model.diagnostics.deliveredFPS))
            LabeledContent("Dropped frames", value: "\(model.diagnostics.droppedFrames)")
            LabeledContent("Source crop detail", value: "\(Int(model.diagnostics.detail.width)) × \(Int(model.diagnostics.detail.height))")
            Button("Prepare diagnostic report") { diagnosticFile = model.diagnosticURL() }
            if let diagnosticFile { ShareLink("Share diagnostics", item: diagnosticFile) }
        }
    }
    private var metadataSection: some View {
        Section("Standard capture metadata") {
            Toggle("Location", isOn: model.binding(\.includeLocationMetadata))
            Text("Original EXIF, capture time, actual exposure, ISO, aperture, lens, dimensions and Live Photo pairing metadata are preserved when supplied by the camera. GPS requires Location permission and a recent fix.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Add optional author metadata", isOn: model.binding(\.customMetadataEnabled))
            if model.settings.customMetadataEnabled {
                TextField("Title", text: model.binding(\.metadataTitle))
                TextField("Author", text: model.binding(\.metadataAuthor))
                TextField("Copyright", text: model.binding(\.metadataCopyright))
                TextField("Description", text: model.binding(\.metadataDescription), axis: .vertical)
                TextField("Keywords, comma separated", text: model.binding(\.metadataKeywords))
            }
        }
    }
    private var savingSection: some View {
        Section("Saving") {
            Toggle("Also save to Photos", isOn: model.binding(\.saveToPhotos))
            Text("Original files are retained in the app first. Photos denial or export failure never deletes the local original. Share individual files or the complete capture pair from the library.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var aboutSection: some View {
        Section("TrueCamera") {
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
            Text("Native capture · local neural scene analysis · faithful color intent · manual ownership")
                .font(.caption).foregroundStyle(.secondary)
            Link("Source and build information", destination: URL(string: "https://github.com/Eabusham2/TrueCamera")!)
        }
    }
}
