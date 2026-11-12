# Source attribution

TrueCamera reuses camera infrastructure, motion/crop geometry, preview/recording components and regression tests from Eyad's [HorizonCamera](https://github.com/Eabusham2/HorizonCamera), verified source commit `6b7cf4e482c744ef1bb0b15eef8df38abe840eb8`, under the repository owner's instruction to reuse that work in this new project.

The synthetic looks, portrait relighting/blur and bracket-fusion renderer have been removed. TrueCamera adds neural scene-guided capture control, explicit original RAW/Live pairing, precise exposure ownership, lossless ProRAW representation, measured camera telemetry and preview-only shooting aids.

Apple Vision models are supplied by the operating system. This repository does not redistribute third-party model weights. Apple platform frameworks remain governed by their respective terms.
