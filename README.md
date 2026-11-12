# TrueCamera

[![iOS build and tests](https://github.com/Eabusham2/TrueCamera/actions/workflows/ios-release.yml/badge.svg)](https://github.com/Eabusham2/TrueCamera/actions/workflows/ios-release.yml)

**A native iPhone camera that uses on-device neural scene analysis to control real camera settings.** It aims for faithful capture, preserves native originals, offers independent manual overrides, and never generates or retouches image content.

[Download builds](https://github.com/Eabusham2/TrueCamera/releases) · [CI](https://github.com/Eabusham2/TrueCamera/actions) · [AI model card](Docs/AI_MODEL_CARD.md) · [Architecture](Docs/ARCHITECTURE.md) · [Physical-device checks](Docs/DEVICE_TESTS.md)

## What the AI actually does

TrueCamera runs four **pretrained Apple Vision models on the phone**: image classification, attention saliency, object saliency, and face landmarks. It uses the inferred subject and scene, camera metering, measured highlight clipping, subject movement and gyro movement to propose:

- Real sensor ISO and exposure duration.
- Exposure compensation when appropriate.
- Real autofocus points, favoring faces/eyes or a salient subject, with focus handover hysteresis.
- Stable native white balance, reacquiring it when the scene or illuminant changes.
- Real physical aperture on a supported variable-aperture camera with iOS 27+.

The neural interpretation and the camera-control policy are distinct: **Apple supplies the trained vision models; TrueCamera supplies a deterministic physical optimizer and safety limits.** This is not a claim of a separately trained aesthetic or photographic-quality model. No pixel enhancement model, image generation, LUT, beauty filter, synthetic blur, color style, relighting, denoising model or invented detail is applied by TrueCamera.

Inference runs asynchronously at up to 2 analyses per second and slows under thermal pressure. Only one analysis frame is in flight. Preview and recording do not wait for inference. Expiring decisions are checked against the current camera configuration before they can control the device. Model confidence is scene confidence, **not** a photo-quality score.

Tap the **AI** control to enable or disable AI globally. In **Settings → Manual**, select **AI / Camera / Manual** independently for exposure, focus and white balance. Manual settings own their parameter until AI is selected again. Tap focus also takes focus ownership from AI. Measured ISO, shutter and aperture appear on the main camera strip; proposals are kept separately in AI diagnostics.

## One shutter: maximum RAW + a Live Photo

Dual capture is the default Photo configuration. The app validates both requested captures before starting and performs:

1. **Maximum RAW master + standard companion.** Apple ProRAW is requested as a lossless DNG at the maximum bit depth supplied by the system, using the largest advertised photo dimensions. The user can choose Bayer RAW instead.
2. **A separate maximum-quality Live Photo.** HEIF, or JPEG when selected, is requested at codec quality 1.0 and photo-quality prioritization `.quality`, with its native paired movie.

The result is **two capture entries**, grouped by a pair ID: one RAW/standard asset and one Live asset. They are consecutive exposures, not two encodings of precisely the same instant. Movement can differ, and full-resolution processing can introduce a delay between them. Each has its own genuine capture time and resolved dimensions.

The app preserves the DNG, processed still and Live movie resources directly from AVFoundation. RAW/Live originals do not pass through TrueCamera's geometric renderer. A partial failure retains completed originals and reports which part failed. It never quietly substitutes a JPEG for RAW or a normal still for a requested Live Photo.

### Choose the kind of original you want

| Choice | What it contains | Important limit |
|---|---|---|
| Apple ProRAW | Apple's computational, demosaiced/linear RAW pipeline, saved as lossless DNG | It is not an untouched Bayer mosaic, nor a promise of literally uncompressed storage |
| Bayer RAW | Minimally processed sensor mosaic | Often lower resolution than ProRAW on a quad sensor |
| HEIF / JPEG | Apple's processed standard photo, requested at the highest codec quality | The Apple ISP still processes the image; TrueCamera adds no look |
| Live Photo | A native processed still plus the matched movie | Maximum available dimensions depend on the active camera/combination |
| Dual ProRAW + Live | Two successive native capture requests | ProRAW and Live cannot share one request |
| Single Bayer RAW + Live | RAW, processed still and a Live movie in one supported native request | Offered only when that active configuration supports it |

**Maximum means the largest supported request for the active lens and capture path.** It is not a hard-coded megapixel promise. The gallery summary and **Original file metadata** inspector show the delivered dimensions, container, actual EXIF exposure, aperture, lens, time and GPS when present.

### Exact exposure versus maximum Apple quality

Apple documents a real tradeoff: custom ISO/shutter is honored by `.speed` photo prioritization. `.balanced` and `.quality` can change exposure for Apple's computational processing. High-resolution photo capture also has quality-priority requirements.

- **Maximum dual capture:** uses `.quality`, keeps the largest advertised request, and preserves the actual resulting EXIF settings.
- **Exact ISO / shutter:** uses `.speed`, chooses a compatible resolution and disables automatic still stabilization. Turn off Dual before selecting it.

The app rejects incompatible exact/max combinations. It does not promise a maximum-quality fused photo used exactly the AI or manual preview exposure.

## Controls and modes

The camera starts at 1×. Settings persist, while live zoom, torch and AE/AF lock reset at launch. Mini overview is on; frame statistics, histogram, zebras and peaking are off. Camera chrome is a neutral dark canvas; settings follow system appearance.

| Area | Controls |
|---|---|
| Photo | Native HEIF/JPEG, lossless ProRAW, Bayer RAW, Live Photo, dual originals, discovered resolutions, quality priority, exact exposure, flash, timer, shutter/burst lock |
| Exposure | AI/camera/manual, real ISO range, full supported still exposure duration, video shutter speed or angle, EV compensation, AE/AF lock |
| Focus | AI subject/eye point, continuous AF, tap focus, manual lens position, smooth AF, face AF, near/far/full range where supported |
| White balance | AI stability, continuous camera AWB, lock, manual Kelvin and tint |
| Aperture | Hardware-measured f-number; manual/AI iris control only when the device and iOS 27 API support the requested combination |
| Video | 720p/1080p/2.8K Action/4K and RAW sensor frame sizes when supported; 23.98/24/25/29.97/30/48/50/59.94/60/100/120/240 fps catalog |
| Encoding | H.264/HEVC, ProRes 422 LT/422/HQ, ProRes RAW/RAW HQ when exposed; SDR, HLG, Dolby-compatible HLG, Apple Log/Log 2 on supported paths |
| Timing | Real-time video, separately retimed 120/240 fps slow motion, interval-based time-lapse, supported locked video frame duration |
| Video operation | Record/stop, long-press QuickTake and recording lock, still frame during recording, native spatial video where supported |
| Audio | Microphone switch, mono, supported stereo/spatial audio, wind-noise removal |
| Framing | Physical-lens snap dots, continuous zoom, pinch-to-point zoom, lens flip, front mirroring, compatible video aspect ratios |
| Native optics/data | Supported lens distortion correction, virtual-camera fusion, sensor orientation compensation, depth/mattes/calibration as auxiliary data only |
| Preview | Grid, level, full-lens overview, frame statistics, real histogram, clipping stripes, edge peaking, Live Text and QR detection |
| Hardware controls | Active-app Camera Control capture events and supported zoom/exposure/focus controls |
| Metadata | Native EXIF/TIFF and capture time; GPS with permission/recent fix; optional title/author/copyright/description/keywords |
| Library | Local originals first, Photos export, full Live playback, DNG sharing, sharing all original resources in a pair, file metadata inspector |

Unavailable choices are disabled where capabilities identify them. Capture/recording performs an additional active-format validation and returns a reason if the combination is unsupported. Format, lens and session changes are blocked while recording; safe manual/AI controls remain adjustable.

This is a substantial native manual-camera implementation, **not a claim of complete feature parity with Blackmagic Camera, ProCamera or Final Cut Camera**. Log is an encoding for a color-managed workflow, not a stylistic filter. ProRes RAW follows Apple's external-storage requirements; ordinary formats have no arbitrary free-space quota imposed by this app.

## Stabilization from HorizonCamera

Reused and adapted from [Eyad's HorizonCamera](https://github.com/Eabusham2/HorizonCamera/tree/6b7cf4e482c744ef1bb0b15eef8df38abe840eb8):

- **Horizon Lock:** gravity/gyro roll correction with a constant safety crop.
- **Floating Zoom Lock:** counter-sliding crop inside source headroom; it sticks at an edge and immediately regains travel when pan direction reverses.
- **Action:** stronger gyro translation/rotation correction on recorded output.
- **Smart:** gentler output correction and artifact headroom.
- **Native stabilization:** actual AVFoundation choices, including low latency on supporting formats. Action native assist is connected when it is compatible.

Custom stabilization only changes geometry. It can crop, resample and reduce effective detail. Action/Smart's heavier correction stays out of the live preview to avoid adding that processing delay; Horizon/Zoom geometry appears in both. Native HDR/Log/ProRes/high-rate paths keep their native precision and disable incompatible custom transforms. Sensor RAW and Live originals remain untouched.

Histogram, zebras and peaking are **preview-only aids**. They describe the processed preview, not a calibrated measurement of all RAW highlight headroom. Edge peaking is an aid, not proof that the intended subject is in focus.

## Metadata, storage and privacy

- First use requests Camera, Microphone, Photos, When-In-Use Location and Motion as applicable.
- AI inference is local. The app has no account, API-key field, analytics endpoint or image-upload service.
- Original files are saved in `Documents/Captures` before Photos export. Denial of Photos access retains the local originals and sharing still works.
- Native camera metadata and Live pairing metadata are preserved. GPS is added only with permission and a recent location fix. PhotoKit creation time/location are populated from the capture.
- Location is enabled by default and can be turned off. Optional custom author/title metadata is off by default.
- Routine successful saves are silent. Failed export or capture is reported.
- Files unindexed after an interruption can be recovered into the local library on the next launch.
- Diagnostic exports contain configuration/telemetry, not images, audio or location coordinates.

## Build, test and IPA

The deployment target is **iOS 17+**. The release workflow uses **Xcode 27+** to compile current physical-aperture APIs and capability-gates newer features at runtime. A physical supported iPhone is needed for camera capture; a simulator can execute rendering, model, metadata and control-policy tests.

```bash
python3 Scripts/generate_project.py
swift test --parallel
bash Scripts/test_simulator.sh
bash Scripts/build_unsigned.sh
```

Open `TrueCamera.xcodeproj` after generating it with your selected Xcode. There are no third-party Swift dependencies, downloaded model weights, account credentials or API keys. The project generator uses the installed iPhone SDK to enable the iOS 27 aperture bridge.

### CI gates

1. Select the newest installed **stable** Xcode 27+.
2. Generate and lint project/privacy metadata.
3. Execute Swift core geometry, motion, exposure-policy, capture-planning and timing tests.
4. Compile the simulator app.
5. Execute iOS tests, including **real Vision inference**, unchanged-source pixels, geometry, preview aids, saved movie/audio, native-metadata preservation and encoded metadata read-back.
6. Build the Release **ARM64 iPhone** app.
7. Package an **unsigned IPA** and verify its bundle, platform, privacy descriptions, Mach-O architecture and absence of signing material.
8. Upload the IPA, SHA-256 and build metadata; publish a tagged GitHub release only after all preceding gates succeed.

**The IPA is unsigned.** Sign it using your own certificate/profile or a compatible sideloading tool before installation. CI does not possess or require an Apple developer identity.

Green CI proves those automated gates passed. It does **not** prove physical-camera color accuracy, hardware aperture travel, maximum RAW/Live behavior, real-world stabilization or sustained thermal performance. Use [the device test plan](Docs/DEVICE_TESTS.md) before treating any build as camera-quality validated.

## Design and source references

- [Apple: RAW and ProRAW capture](https://developer.apple.com/documentation/avfoundation/capturing-photos-in-raw-and-apple-proraw-formats)
- [Apple: Capture and process ProRAW images](https://developer.apple.com/videos/play/wwdc2021/10160/)
- [Apple: Implement high resolution photo capture](https://developer.apple.com/videos/play/wwdc2026/304/)
- [Apple: Physical aperture, ISO and shutter control](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setexposuremodecustom(lensaperture:duration:iso:completionhandler:))
- [Apple: Lossless ProRAW representation](https://developer.apple.com/documentation/avfoundation/avcapturephotofiledatarepresentationcustomizer/replacementappleprorawcompressionsettings(for:defaultsettings:maximumbitdepth:))
- [Apple: Vision image classification](https://developer.apple.com/documentation/vision/classifying-images-for-categorization-and-search)
- [Apple: Saliency models](https://developer.apple.com/videos/play/wwdc2019/222/)
- [Apple: Native photo metadata](https://developer.apple.com/documentation/avfoundation/avcapturephotosettings/metadata)
- [GitHub: Runner images and current Xcode labels](https://github.com/actions/runner-images)
