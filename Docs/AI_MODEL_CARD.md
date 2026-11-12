# TrueCamera on-device scene intelligence

## What the AI actually does

TrueCamera runs **Apple's trained Vision models on real camera preview frames**. A neural scene classifier supplies semantic labels; attention and objectness saliency models locate likely subjects; face landmarks locate eyes. These results materially affect the focus point and the exposure optimizer's motion / depth-of-field choices. Recognition is not replaced with a color histogram or a list of scene thresholds.

The app's camera-control policy then combines those model outputs with the physical lens limits, the camera's metered exposure offset, measured highlight clipping, observed movement of the detected subject, and gyroscope movement. It proposes real ISO, shutter duration, exposure bias, focus point, native white-balance mode, and physical aperture where the camera exposes a variable aperture. This last stage is a documented analytic optimizer with safety bounds, **not a separately trained photographic-quality model**.

The app does not claim that a neural network trained to rate color accuracy or recover absolute scene radiance has been built. There is no such custom dataset, hidden learned controller, downloadable model, or quality benchmark in this repository. Apple's model parameters and training datasets are managed by the operating system. Recognizer confidence is displayed as **scene confidence**, never a score for photograph quality.

## Models and sources

| Model / API | Output used by TrueCamera | Source |
|---|---|---|
| `VNClassifyImageRequest` | Top scene labels and confidence, used to set subject-motion priorities | [Apple API](https://developer.apple.com/documentation/vision/vnclassifyimagerequest), [Apple's description of its on-device classification network](https://developer.apple.com/videos/play/wwdc2019/222/) |
| `VNGenerateAttentionBasedSaliencyImageRequest` | Likely attention region for focus | [Apple API](https://developer.apple.com/documentation/vision/vngenerateattentionbasedsaliencyimagerequest) |
| `VNGenerateObjectnessBasedSaliencyImageRequest` | Foreground subject region, with temporal continuity | [Apple API](https://developer.apple.com/documentation/vision/vngenerateobjectnessbasedsaliencyimagerequest) |
| `VNDetectFaceLandmarksRequest` | Face and eye locations for autofocus | [Apple API](https://developer.apple.com/documentation/vision/vndetectfacelandmarksrequest) |

Apple describes both saliency models as deep neural networks. Attention saliency is trained from human eye-tracking observations; objectness saliency is trained on segmented foreground subjects. [Apple saliency documentation](https://developer.apple.com/documentation/vision/cropping-images-using-saliency)

## No generated or retouched image content

SceneIntelligence has no output image pipeline. It reads a reduced copy of the camera preview and emits scalar control proposals. It never mutates the camera pixel buffer, paints detail, performs neural denoising, changes skin, synthesizes exposures, or applies a style/LUT. RAW and native photo outputs come from AVFoundation. Native Apple processing still applies to Apple ProRAW / HEIF / Live Photo according to their formats; Bayer RAW is a separate option. Gyroscope stabilization is crop/rotation geometry and is separate from this AI module.

## Exposure and color decisions

- The optimizer chooses among feasible ISO and shutter combinations. It penalizes metered-exposure error, noise and motion blur, while damping unnecessary setting changes.
- Moving subjects inferred from the model, or detected subject/camera movement, favor shorter exposures. A stationary broad scene can favor depth of field when a physical variable aperture and enough light are available.
- Highlight protection changes capture exposure. It is not a tone-mapping curve applied to saved pixels. Measurements come from the preview, so they are an estimate of sensor/RAW clipping, not a RAW saturation detector.
- The native camera's white-balance measurement estimates the illuminant. AI waits for a stable scene before holding those gains, and returns to continuous native measurement when scene color, brightness, motion, or measured temperature changes. No warm/cool look is added. A neutral reference and manual white balance remain necessary for measured color work.
- Exact exposure and maximum-resolution Apple photo quality are different capture policies: Apple's high-quality still pipeline can adjust/fuse captures. The capture controller reports what was actually delivered; AI does not guarantee Apple will retain preview ISO/shutter in every photo-quality mode.

## Control ownership and timing

Each parameter has an independent AI toggle. Manual exposure, manual focus, AE/AF lock, manual white balance, white-balance lock and manual aperture suppress the relevant proposals. The capture session rechecks those conditions before applying them. Proposals carry a configuration revision and a short monotonic expiry; capture, lens switching, reconfiguration, stopping and manual changes invalidate in-flight analysis.

Small subject movements update the focus target immediately. A large jump to another model-detected region needs two consecutive observations before focus transfers, avoiding a single-frame detection flicker that would hunt between subjects. User tap focus retains manual ownership until AI focus is enabled again. Analysis status carries the same revision and timestamp protection as control proposals.

At most one camera buffer is retained by the analyzer. It skips surplus frames instead of adding latency to the preview or building a queue. Normal analysis is capped at 2 Hz, dropping to 1 Hz or 0.5 Hz under serious/critical thermal pressure. Images are reduced to at most 512 pixels on the long edge. Inference runs on a utility queue; the capture queue applies the proposed scalar settings. Apple's runtime chooses device compute resources; simulator tests use CPU execution of the real models.

## Privacy

There are no AI network requests, cloud API keys, uploads, identities, face recognition or face templates. Facial landmarks are short-lived geometry used for focus. The module retains only the current analysis buffer and previous scalar scene evidence; it does not persist the preview or scene history.

## Verification and remaining evidence

Core tests check that neural semantic inputs change real exposure proposals, motion changes shutter choices, camera bounds hold, manual ownership prevents changes, stale/reconfigured results are rejected, invalid numerical inputs are rejected, and unsupported fixed apertures receive no fake proposal. iOS tests execute all four Apple Vision requests against a deterministic fixture and verify that source pixels remain byte-for-byte unchanged.

Those tests establish model execution, control-policy invariants and read-only image behavior. They do **not** establish recognition accuracy, accurate skin tone across illuminants, optimal detail/noise, shutter timing on hardware, or superiority to the Apple Camera app. Hardware validation should include a gray card / color chart under daylight, tungsten and mixed lighting; static and moving subjects; lens and light transitions; sustained recording and thermal pressure; and EXIF/read-back comparisons between requested and delivered settings.
