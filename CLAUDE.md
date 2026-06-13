# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**Arcus** — an iOS app that turns a single 2D photo into an interactive 3D photo **fully on-device** (offline, no server): tilt/drag produces motion parallax, and moving the subject reveals an inpainted background behind it (Apple "spatial scene" look). Pure system frameworks, **zero third-party SPM/Pod dependencies**; the only external assets are Core ML models downloaded at setup.

Single Xcode project `Arcus.xcodeproj`, scheme `Arcus`, bundle id `com.arcus.app`, deployment target **iOS 17.0**.

## Build & run

```bash
# Simulator compile check (CI / fast validation)
xcodebuild -project Arcus.xcodeproj -scheme Arcus \
  -destination 'generic/platform=iOS Simulator' -configuration Debug build

# Real-device build (needs signing); installs the full ANE/GPU experience
xcodebuild -project Arcus.xcodeproj -scheme Arcus \
  -destination 'generic/platform=iOS' -configuration Release -allowProvisioningUpdates build

# Deploy to a connected device after a Release build
xcrun devicectl device install app  --device <UDID> <path-to>.app
xcrun devicectl device launch app   --device <UDID> com.arcus.app
```

There is no test target, no linter, no package manifest. "Validation" means it compiles and runs. The project uses `objectVersion 77` **file-system-synchronized groups**: any `.swift` file added under `Arcus/` is auto-included in the target — no `project.pbxproj` edit needed.

Real-device-only behavior: gyro parallax and `VNGenerateForegroundInstanceMaskRequest` subject segmentation require ANE/GPU; the Simulator silently falls back to depth-threshold segmentation and has no gyro.

## Performance — measure on Release/device, never Debug/Simulator

The one-shot pipeline is **per-pixel CPU numeric loops** (depth post-process, push-pull / PatchMatch fill, resampling). Under Debug (`-Onone`) these run **30–50× slower**, and `swift somefile.swift` runs fully unoptimized too. A 768×1024 image is ~0.3s in Release but can take 10+ seconds in Debug/Simulator — that is expected, not a regression. Always judge speed with a Release build on device. Timing is logged as `[Pipeline] 完成 WxH 用时 …s`.

## Models (downloaded, gitignored under `Arcus/Resources/*.mlpackage/`)

```bash
./scripts/download_models.sh   # DepthAnythingV2SmallF16 (~48MB) + LaMa (~38MB)
```

MI-GAN is **not** an off-the-shelf Core ML model — convert it locally (the active "AI fill" path):

```bash
uv venv --python 3.12   # torch/coremltools have no 3.13 wheels
uv pip install torch coremltools numpy onnx onnx2torch
# download migan.onnx, then:
python scripts/convert_migan.py   # → Arcus/Resources/MiGAN.mlpackage (FP16, ~14MB)
```

Every model is optional — missing models degrade gracefully, never crash: no depth model → pseudo-depth; LaMa missing → push-pull; MI-GAN missing → PatchMatch.

## Architecture

The whole app is: a **one-shot CPU/Metal pipeline** that bakes GPU textures into a `Photo3DScene`, then a **real-time Metal renderer** that forward-warps those textures every frame.

### Pipeline (`Arcus/Pipeline/`, runs once per photo, result cached)

`Photo3DPipeline` orchestrates: **depth → segment → disocclusion fill → bake**.

- `DepthEstimator` — `AVDepthData` (LiDAR/portrait) if present, else Depth Anything V2 Small via `VNCoreMLRequest`, else pseudo-depth. Output is disparity (0=far, 1=near).
- `SubjectSegmenter` — `VNGenerateForegroundInstanceMaskRequest` → person segmentation → depth-threshold fallback. Soft-alpha matte.
- `DisocclusionInpainter` — fills the subject region in both color and disparity so the background layer has content behind the subject. Static fills: `verticalFill`, `patchMatchFill` (depth-gated sources + depth-SSD term), `planarFill` (least-squares plane, used for MI-GAN's depthless invented content), `pushPullFill`.
- `LamaInpainter` / `MiganInpainter` — learned Core ML inpainters. Both crop to the hole bbox + context margin → resize 512 → run model → soft-composite back only inside the hole (full-res real background is kept outside the silhouette).
- `Photo3DScene` — the bake contract handed to the renderer: `fgColor` (RGBA, alpha=matte), `fgDepth`, `bgColor` (inpainted), `bgDepth` (inpainted), plus `fgCenter`/`midCenter` centroids and an optional mid layer (`MultiLayer`; the viewer's 背景分层 toggle that renders it defaults **on**).

`FillMode` (top-level enum in `Photo3DPipeline.swift`) selects the inpainter — `.fast` (vertical+depth), `.patchMatch` (PatchMatch+depth), `.migan` (MI-GAN, falls back to PatchMatch if the model is absent). Surfaced as a segmented picker on the start screen; held on `AppModel.fillMode`.

### Rendering (`Arcus/Rendering/`)

**Not** displacement-along-Z planes. Each layer is one continuous image-uv grid; the vertex shader samples disparity at `uv0` and **forward-warps the screen position** by `offset * parallaxAmp * (d - depthPivot)`. Continuous warp ⇒ no onion-ring layering artifacts; the foreground grid is cut at silhouette/depth cliffs ⇒ no rubber-sheet stretching. The subject is **scaled up about its centroid** (`base = fgCenter + (uv0-fgCenter)*fgScale`, texture still sampled at `uv0`) so the enlarged silhouette covers the disocclusion transition band — it magnifies, not translates. Mid layer scales at 0.6× of the FG factor about its own centroid.

- `MeshBuilder` builds the shared (u,v) vertex grid: the **bg index buffer is the full grid** (one continuous surface), the **fg index buffer drops quads whose 4 corners straddle a depth cliff** (`tauCut`) — that's the silhouette cut that exposes inpainted background.
- `ParallaxRenderer` drives it (state lives on `ViewerParams`); `MotionController` supplies clamped/low-passed CMMotion attitude; `ParallaxMetalView` bridges to SwiftUI + gestures.
- **Silhouette anti-aliasing is a three-layer fix** (see `docs/10`): the segmentation matte is low-res and stair-stepped, so the *real* fix is in the pipeline — `FloatImage.guidedRefinedColor` (RGB-guided joint-bilateral upsampling) snaps the matte to true image edges. The fragment shader adds `fwidth(c.a)` analytic AA, and the pipeline keeps the matte cinch wide (`smoothStep(0.42,0.58)`) to leave a gradient. MSAA does **not** anti-alias the alpha silhouette (only geometry cuts) — don't rely on it.

**Spatial Reframe (「重拍」**, see `docs/11`) — an additive, default-off mode (`ViewerParams.reframeMode`/`zoomLevel`, `ReframeController` in `ParallaxMetalView.swift`, `ReframeStage` in `EditorView`). It reuses the **same** MTKView/renderer; normal viewing is byte-identical when off (pan springs back, zoom resets on exit). Normal viewing letterboxes at the original aspect (`ViewerParams.fitImage = true`, the default); reframe's immersive stage flips it to cover-and-crop. Two-stage like Apple Spatial Reframing: (1) **preview** — drag the virtual camera (large `parallaxAmp`, no spring-back), revealed frame edges get a frosted-glass placeholder; (2) **「补全这一视角」** — render the chosen camera to a full-res still + a **hole mask**, run LaMa (→ MI-GAN fallback) to generate sharp pixels. The hole = pixels-pushed-out-of-frame ∪ background-revealed-behind-the-subject; the latter comes from a `fillMask` baked into **`bgColor` alpha at processing time** (normal rendering never reads bg alpha). **Caveat:** regenerating behind-the-subject needs a photo processed by a build that bakes that fillMask — old cached scenes lack it.

**Frame pop-out (「出框」**, see `docs/15`) — a default-off draw-order trick (`ViewerParams.frameBars`): a pair of screen-space **static** near-white bars is drawn between the background/mid layers and the foreground (order bg → mid → bars → fg). The background moves behind the bars while the subject occludes them — the naked-eye-3D pop-out cue, with occlusion guaranteed by draw order (no depth buffer). Bars are skipped whenever `debugMode != 0` so debug layers and the reframe hole-mask pass stay clean, and `EditorView` forces `frameBars = false` on reframe params. `VideoExporter` goes through the same `encodeMesh`, so exporting with bars on deliberately yields a "pop-out video".

### Export (`Arcus/Export/`)

`VideoExporter` (parallax loop mp4 via off-screen render), `SpatialPhotoExporter` (stereo HEIC viewable on Vision Pro), `MediaSaver`.

### UI (`Arcus/UI/`)

`AppModel` is the `@ObservableObject` state machine (idle → processing → editor); `ContentView` switches stages; `ProcessingView` shows the one-shot run; `EditorView`/`ControlsView` host the 3D preview, params, debug layers, reframe entry, and export; `ExportResultView` shows the saved artifact. The bottom debug-layer picker maps to the shader's `debugMode` (e.g. `2` = raw subject matte, `4` = fillMask) — handy when diagnosing matte/fill issues.

### Core (`Arcus/Core/`)

`FloatImage` is the CPU pixel buffer the entire pipeline operates on — row-major `[Float]`, values ~0…1, `channels` 1 (depth/mask) or 3/4 (color), with `cropped`/`resized`/`dilated`/sampling helpers. `MetalContext` (shared device/queue/library), `TextureIO`, `ImageUtils`, `AuxDepthLoader`.

## Cross-file invariants (easy to break silently)

- **`MeshUniforms` must have identical memory layout in Swift (`ParallaxRenderer.swift`) and Metal (`Shaders.metal`).** Fields are commented with byte offsets (`offset 0` … `fgCenter` at 48, stride 56). When you add/reorder a field, update both and verify with `MemoryLayout.offset(of:)` — a mismatch corrupts rendering with no compile error.
- **Robustness fallbacks are load-bearing**, not optional polish — every stage (depth, segmentation, each inpainter) degrades instead of crashing. Preserve that when editing.

## Conventions

- **Comments are in Chinese; identifiers in English.** Match the surrounding density and idiom when editing.
- No new third-party dependencies — system frameworks only (SwiftUI, Vision, CoreML, Metal, MetalPerformanceShaders, CoreMotion, AVFoundation, ImageIO, Photos).
- Don't commit models; `Arcus/Resources/*.mlpackage/` is gitignored and bundled automatically by Xcode at build time.

## Docs (`docs/` — gitignored, local-only; absent on fresh clones)

`01-research.md` (core research), `02-architecture.md`, `03-build-and-run.md`, `04-competitive-analysis.md`, `05-roadmap-status.md`, `06-parallax-rendering-redesign.md`, `07-foreground-scale.md`, `08`/`09` disocclusion-fill research, `10-edge-antialiasing.md` (silhouette-AA root-cause + fix), `11-spatial-reframe.md` (the 「重拍」 mode), `12-industry-2d-to-3d-onepager.md` (transcribed industry survey — Apple/PICO/Meta/Samsung/XReal 2D→3D, the disparity math, on-device depth), `13-naked-eye-3d-from-ios26.md` (transcribed first-principles explainer — disparity↔depth geometry, autostereograms, single-image depth, gyro parallax, fg/bg black-frame video + temporal-consistency & segmentation gotchas), `14-tech-share-2d-to-3d.md` (tech-share narrative draft — fact-checked 2024–2026 industry timeline through WWDC26 Spatial Reframing, with Arcus as the running demo), `15-frame-pop-out.md` (the 「出框」 frame-bars feature: rationale, draw-order design, trade-offs). **Caveat:** `02`/`03` predate the rendering rewrite and the MI-GAN work — they still describe a `Compute/` directory, `PlaneMesh.swift`/`Render.metal`/`DepthProcessor.swift`, and a displacement-mesh renderer that no longer exist. Trust the source tree above (and `06`+) over the older module lists in `02`/`03`.
