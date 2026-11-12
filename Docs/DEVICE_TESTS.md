# Physical iPhone validation

CI can prove compilation, deterministic policy behavior, real simulator Vision execution, unchanged source buffers, pixel transforms, encoded metadata and the unsigned package. It cannot exercise an iPhone sensor. These checks remain required on each supported hardware family.

## Original capture and metadata

1. Grant Camera, Microphone, Photos, Location and Motion on first launch; relaunch and confirm permissions are not repeatedly requested. Repeat with optional permissions denied. Camera denial must give a clear path to Settings; Photos denial must preserve local files.
2. On each physical lens, inspect the offered maximum dimensions and ProRAW/Bayer availability. Unsupported choices must not produce a differently typed fallback file.
3. Capture the default ProRAW + Live pair. Verify two library entries, the first containing DNG plus its companion and the second containing the native still/Live MOV. Open both exported assets in Photos. Verify RAW identity, genuine Live playback and independent EXIF timestamps/dimensions.
4. Check a 48 MP-capable camera under appropriate light. Record requested and delivered dimensions separately. Compare EXIF width/height, ISO, shutter, f-number and lens with a trusted metadata reader. Check lossless DNG compression/bit depth; do not infer either from filename or file size.
5. Test single Bayer RAW + Live if supported. Test ProRAW + Live without Dual and verify an incompatibility reason. Test exact exposure at several ISO/shutter combinations; compare actual EXIF against the selected values.
6. With location allowed and a recent fix, confirm GPS and Photos asset location/time. Disable location and verify subsequent captures omit app-added location. Verify author fields remain absent by default.
7. Interrupt or background during each step; simulate storage/export failure where possible. Completed originals must remain recoverable; incomplete pairs must be reported rather than called complete. Share the complete original resource set and inspect each file.

## AI and manual control

1. Check the AI status shows active model inference and measured telemetry changes under changing light. Cover/uncover the camera; avoid runaway ISO or oscillating exposure.
2. Compare stationary detail, faces, moving people/pets and high-contrast subjects. Verify focus is driven toward the inferred subject and does not jump on every isolated detection. Camera switch/zoom/tap must invalidate previous proposals.
3. Change each parameter to Manual while AI is active. It must stay at the requested supported value until returned to AI. Verify tap focus cannot be immediately undone. Repeat safe controls during both custom and native recording.
4. Record a neutral chart under daylight, tungsten, mixed and changing light. Evaluate white-balance reacquisition and color error against a known reference. Do not equate subjective vividness or scene confidence with physical accuracy.
5. On iOS 27 variable-aperture hardware, confirm reported range and observe real aperture/EXIF changes. Unsupported fixed lenses must not expose a simulated aperture slider. Validate combinations with manual shutter/ISO and AI aperture.
6. Run sustained use and monitor camera/system pressure, thermal throttling, preview responsiveness and recording frame drops. Measure latency on hardware rather than estimating from simulator performance.

## Stabilization and recording

1. Sweep Horizon Lock through portrait/landscape/full rotations; check black corners, constant crop, leveling and motion calibration. Test near vertical singularities and interrupted motion samples.
2. At zoom, pan to both limits, reverse direction and verify floating crop travel resumes immediately. Confirm Action can coexist with Zoom Lock and does not add its heavy output-only processing to preview.
3. Inspect recorded video to confirm Action/Smart changed output geometry. Check native low-latency/standard modes on supported formats. Do not claim Apple Action Mode equivalence.
4. Exercise each supported resolution/rate/codec/color profile, including real-time 120/240 versus slow-motion and time-lapse. Verify recorded dimensions, frame cadence, audio synchronization, color tags and actual codec externally.
5. Verify native ProRes/HDR/Log paths reject incompatible custom geometry; validate Apple-required external storage for ProRes RAW. Return from native video to Photo and confirm Live Photo becomes usable again.
6. Confirm histogram/zebra/peaking overlays never appear in any stored photo or movie. Compare clipping guides against processed preview, without interpreting them as a RAW-headroom measurement.

Record device model, iOS version, app commit, camera/lens, settings and the actual artifact for each finding. Do not upload private photos or location data without the owner's approval.
