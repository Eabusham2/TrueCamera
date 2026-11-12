# TrueCamera architecture

## Ownership and concurrency

`CameraModel` owns observable UI/persistent preferences on the main actor. `CaptureEngine.sessionQueue` owns the capture session, active device, configuration revision, physical controls, shot coordinator and camera state. `frameQueue` owns stabilization state and movie frame writing. `SceneIntelligence` owns a serial utility inference queue; a lock protects its in-flight/version state. A separate preview-analysis queue produces display-only aids.

Camera buffers cross into the session queue through a bounded handoff with at most one queued frame. Neural inference accepts at most one buffer, rejects surplus frames and downsamples to 512 pixels before executing actual Apple Vision networks. The preview and encoder never wait for a neural result. Every proposal carries a monotonic source timestamp, expiry and configuration revision. The session queue checks all three and rechecks manual control ownership before touching a camera.

Configuration changes, physical zoom changes, taps, hardware controls, native recording transitions and still-capture transitions invalidate obsolete inference. AI is paused for both stages of a dual capture. Large subject-target jumps require confirmation to avoid one-frame focus hunting. Recorded formats cannot be changed during recording; safe control changes are allowed.

## Three image paths

1. **Native still originals.** `AVCapturePhotoOutput` uses the photo session preset. `PhotoCapturePlanner` validates RAW/Live support, exact/quality compatibility and dimensions. `PhotoCapture` retains the encoded resource, original metadata, resolved dimensions and actual capture time. Its ProRAW customizer requests lossless compression and the maximum system-offered bit depth. Files are written directly, with no decode/render/re-encode step.
2. **Native movie path.** `NativeMovieController` uses `AVCaptureMovieFileOutput` for ProRes, HDR/Log, multichannel audio, native spatial video and high-rate real-time video. Codecs, color spaces and stabilization are checked against native support. The idle output is removed before returning to Photo so it cannot disable Live Photos.
3. **Geometric video path.** `FrameProcessor`, `MotionService`, `CropGeometry`, `MetalPreview` and `MovieRecorder` share sensor-driven crop/rotation plans. The encoder receives the actual corrected recording frame. The renderer contains no style, relighting, synthetic portrait or fusion functions. SDR encoding is color-managed/tagged Rec.709; native HDR/Log bypasses this path.

## Dual capture transaction

Both steps are planned and validated before the first exposure. Each step receives a new settings instance. The first is a RAW master plus processed companion; the second is a processed still plus paired Live MOV. Both are saved under a shared pair ID and separate real capture timestamps. A failed second step does not delete the first. Requests never silently degrade RAW to a processed image or Live to a still.

Photo originals always keep their sensor aspect and native files. Physical camera zoom is applied through `videoZoomFactor`, and the preview is not digitally zoomed a second time. Actual resolved dimensions and EXIF are shown in the library rather than inferred from requested options.

## Neural inference versus control policy

The Apple-trained classification, attention, objectness and landmark networks interpret the scene. The app's `ExposurePolicy` is an analytical controller constrained by actual ISO/shutter/aperture ranges. It uses metering error, requested EV, highlight measurements, neural subject type/movement and gyro speed. It proposes real controls and explicitly avoids claiming an aesthetic score or trained optimal-exposure network. White balance uses native AWB plus neural-scene/stability-based hold/reacquisition; it does not neutralize deliberately colored surfaces.

## Stabilization geometry

Horizon estimation unwraps full-turn roll and uses gyro continuation near the gravity singularity. Floating Zoom Lock is an edge-limited gyro crop, not a Vision object-tracker: counter-motion is saturated at crop boundaries so reversal is immediate. Constant rotation headroom avoids scale breathing. Action/Smart apply stronger/gentler output-only motion correction while Horizon/Zoom remain in the preview.

Sensor gaps over 100 ms are rejected by the live motion service. Nonfinite motion, geometry and frame timestamps are rejected. Crop detail and upscaling are measured and exposed; no detail is synthesized.

## Guides, metadata and storage

`CameraAssistOverlay` independently analyzes a maximum 256-pixel preview at up to 4 Hz. Its histogram, clipping stripes and Sobel peaking have no path to stored pixels. Native photo metadata remains intact; location is appended only with authorization and a recent fix. `MediaLibrary` stores files locally before optional Photos export; PhotoKit uses native capture time and extracted GPS. `CaptureFileInfo` reads the actual file metadata for inspection.

The unsigned IPA workflow checks core behavior, real simulator neural/rendering/export paths and the ARM64 package. It does not replace hardware validation.
