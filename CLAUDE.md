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

Smoke-test launch hook (`ContentView.swift`): launch with env `AUTOSAMPLE=1` to auto-process the bundled sample image, and `DEBUGMODE=<n>` to land on a debug layer (`1` depth, `2` subject matte, `3` background, `4` reframe fillMask). Other hooks: `FILLMODE=fast|patchMatch|migan` overrides the inpainter, `AUTOANIM=1` auto-animates the camera, `SCENEMODE=gaussian` selects the splat renderer, `AUTOREPAIR=1` auto-runs viewpoint repair, `AUTOEXPORT=video|gif|live|spatial` auto-exports, `AUTOCAMERA=1` opens the in-app camera (and auto-captures once the camera is ready). Useful for headless device verification, e.g. `xcrun devicectl device process launch --environment-variables '{"AUTOSAMPLE":"1","DEBUGMODE":"2"}' …`.

## Performance — measure on Release/device, never Debug/Simulator

The one-shot pipeline is **per-pixel CPU numeric loops** (depth post-process, push-pull / PatchMatch fill, resampling). Under Debug (`-Onone`) these run **30–50× slower**, and `swift somefile.swift` runs fully unoptimized too. A 768×1024 image is ~0.3s in Release but can take 10+ seconds in Debug/Simulator — that is expected, not a regression. Always judge speed with a Release build on device. Timing is logged as `[Pipeline] done WxH in …s (depth:… subject:… fill:… tris fg:…/bg:…)` — the trailing fields name which depth/segmentation/fill path actually ran, so the log doubles as a fallback-tracer.

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
- `Photo3DScene` — the bake contract handed to the renderer: `fgColor` (RGBA, alpha=matte), `depth` (foreground disparity — note: not `fgDepth`), `bgColor` (inpainted), `bgDepth` (inpainted), plus the `fgCenter` centroid and an optional mid layer (`MultiLayer`, which carries its own `midCenter` centroid; the viewer's 背景分层 toggle that renders it defaults **on**).

`FillMode` (top-level enum in `Photo3DPipeline.swift`) selects the inpainter — `.fast` (vertical+depth), `.patchMatch` (PatchMatch+depth), `.migan` (MI-GAN, falls back to PatchMatch if the model is absent). Surfaced as a segmented picker on the start screen; held on `AppModel.fillMode`.

### Rendering (`Arcus/Rendering/`)

**Not** displacement-along-Z planes. Each layer is one continuous image-uv grid; the vertex shader samples disparity at `uv0` and **forward-warps the screen position** by `offset * parallaxAmp * (d - depthPivot)`. Continuous warp ⇒ no onion-ring layering artifacts; the foreground grid is cut at silhouette/depth cliffs ⇒ no rubber-sheet stretching. The subject is **scaled up about its centroid** (`base = fgCenter + (uv0-fgCenter)*fgScale`, texture still sampled at `uv0`) so the enlarged silhouette covers the disocclusion transition band — it magnifies, not translates. The mid layer applies an **adaptive, depth-dependent** fraction of the FG scale about its own centroid (`midScaleFactor = (dMid/dSubj)²`, the mid/subject mean-disparity ratio clamped to [0,1] — far layers fall off faster), not a fixed multiplier.

- `MeshBuilder` builds the shared (u,v) vertex grid: the **bg index buffer is the full grid** (one continuous surface), the **fg index buffer drops quads whose 4 corners straddle a depth cliff** (`tauCut`) — that's the silhouette cut that exposes inpainted background.
- `ParallaxRenderer` drives it (state lives on `ViewerParams`); `MotionController` supplies clamped/low-passed CMMotion attitude; `ParallaxMetalView` bridges to SwiftUI + gestures.
- **Silhouette anti-aliasing is a three-layer fix** (see `docs/10`): the segmentation matte is low-res and stair-stepped, so the *real* fix is in the pipeline — `FloatImage.guidedRefinedColor` (RGB-guided joint-bilateral upsampling) snaps the matte to true image edges. The fragment shader adds `fwidth(c.a)` analytic AA, and the pipeline keeps the matte cinch wide (`smoothStep(0.42,0.58)`) to leave a gradient. MSAA does **not** anti-alias the alpha silhouette (only geometry cuts) — don't rely on it.

**Spatial Reframe (「重拍」**, see `docs/11`) — an additive, default-off mode (`ViewerParams.reframeMode`/`zoomLevel`, `ReframeController` in `ParallaxMetalView.swift`, `ReframeStage` in `EditorView`). It reuses the **same** MTKView/renderer; normal viewing is byte-identical when off (pan springs back, zoom resets on exit). Normal viewing letterboxes at the original aspect (`ViewerParams.fitImage = true`, the default); reframe's immersive stage flips it to cover-and-crop. Two-stage like Apple Spatial Reframing: (1) **preview** — drag the virtual camera (large `parallaxAmp`, no spring-back), revealed frame edges get a frosted-glass placeholder; (2) **「补全这一视角」** — render the chosen camera to a full-res still + a **hole mask**, run LaMa (→ MI-GAN fallback) to generate sharp pixels. The hole = pixels-pushed-out-of-frame ∪ background-revealed-behind-the-subject; the latter comes from a `fillMask` baked into **`bgColor` alpha at processing time** (normal rendering never reads bg alpha). **Caveat:** regenerating behind-the-subject needs a photo processed by a build that bakes that fillMask — old cached scenes lack it.

**Frame pop-out (「出框」**, see `docs/15`) — a default-off draw-order trick (`ViewerParams.frameBars`): a pair of screen-space **static** near-white bars is drawn between the background/mid layers and the foreground (order bg → mid → bars → fg). The background moves behind the bars while the subject occludes them — the naked-eye-3D pop-out cue, with occlusion guaranteed by draw order (no depth buffer). Bars are skipped whenever `debugMode != 0` so debug layers and the reframe hole-mask pass stay clean, and `EditorView` forces `frameBars = false` on reframe params. `VideoExporter` goes through the same `encodeMesh`, so exporting with bars on deliberately yields a "pop-out video".

### Render modes — LDI vs Gaussian Splatting (`AppModel.SceneMode`, see `docs/17`)

The start screen offers two **rendering schemes** via a `SceneMode` segmented picker (`AppModel.sceneMode`): **`.layeredLDI`** (default — the screen-space mesh-warp renderer above, byte-identical to legacy) and **`.gaussianSplat`** (a true on-device **3D Gaussian Splatting** path, **pure Metal, zero third-party deps, fully offline** — the OpenReshot-beating differentiator, [doc 16](docs/16-openreshot-research.md)). Both reuse the *same* one-shot pipeline: when `sceneMode == .gaussianSplat`, `Photo3DPipeline.Options.buildGaussians` lifts the already-computed FloatImages (subject `color`/`fgDisp`/matte + full inpainted `bgColor`/`bgDepth`) into per-pixel 3D Gaussians via `GaussianSplatBuilder` → `Photo3DScene.gaussianScene` (a synthesized pinhole camera whose canonical view reproduces the photo). `EditorView` branches the renderer host on `isGaussian`: `GaussianMetalView`/`GaussianRenderer`/`GaussianShaders.metal` (EWA splat rasterizer: project→2D conic via perspective Jacobian, per-frame CPU back-to-front counting sort + triple-buffered index ring, premultiplied-over, `sampleCount=1`) instead of `ParallaxMetalView`. **LDI stays nil-`gaussianScene` and unchanged when not selected**; reframe/出框/debug-layers/multi-layer-bg are LDI-only (gated off in Gaussian mode); export still uses the LDI representation. Smoke hook: `SCENEMODE=gaussian`.

The Gaussian viewer adds (docs/17 §10): a **「补全这一视角」 repair** ("Reshot"-style) — `GaussianViewController.snapshot()` → `AppModel.repairCurrentViewpoint` runs on-device LaMa/MI-GAN (`pipeline.reframeInpaint`, offline default) or optional **Google Gemini** cloud (`GeminiRepair`, user key in `GeminiSettingsSheet`), result shown with hold-to-compare + save; a **frosted "cloud" backdrop** (transparent MTKView over a blurred original + glow, no more black on viewpoint reveal); and a **「镜头」 lens dock** — the GaussianRenderer is MRT (color-over + (z·α,α)-over → per-pixel depth) + a DOF/composite pass, with `ViewerParams.gs{Dolly,Focus,FNumber}` (推轨/前后 dolly, focus, f-number DOF). The whole UI is rebuilt on a `Theme.swift` design system (aurora + glass docks). Smoke hooks: `AUTOREPAIR=1`. The repair/cloud step is the only optional network use — everything else stays on-device/offline.

### Export (`Arcus/Export/`)

All exporters share the off-screen `ParallaxRenderer.renderOffscreen` frame loop. The video/gif/live exporters animate the **same figure-8 camera path** (so trajectory work benefits all three); `SpatialPhotoExporter` instead renders a single fixed ±eye-offset stereo pair (no animation loop):
- `VideoExporter` — parallax loop mp4 (H.264).
- `GifExporter` — infinite-loop GIF (ImageIO `CGImageDestination`, lower fps/size); saved via `MediaSaver.saveImage` (byte-preserving → animation kept).
- `LivePhotoExporter` — **Live Photo**: still HEIC + paired MOV sharing one Content Identifier + a `still-image-time` timed-metadata track; `MediaSaver.saveLivePhoto` writes them as `.photo` + `.pairedVideo` of one asset (device-verified: Photos shows the 实况/LIVE badge).
- `SpatialPhotoExporter` — stereo HEIC for Vision Pro. `MediaSaver` — Photos write + add-only auth.

`AppModel.ExportKind` (a plain enum, cases `video`/`spatial`/`gif`/`live`, no associated values) drives the `ControlsView` export grid and `ExportResultView` preview (animated `GIFImageView` for gif, LIVE-badged still for live); the Live Photo's `pairedURL` is carried by the `ExportResult` struct, not the enum. Smoke hook: `AUTOEXPORT=video|gif|live|spatial`.

### UI (`Arcus/UI/`)

`AppModel` is the `@ObservableObject` state machine (idle → processing → editor); `ContentView` switches stages; `ProcessingView` shows the one-shot run; `EditorView`/`ControlsView` host the 3D preview, params, debug layers, reframe entry, and export; `ExportResultView` shows the saved artifact. The bottom debug-layer picker maps to the shader's `debugMode` (e.g. `2` = raw subject matte, `4` = fillMask) — handy when diagnosing matte/fill issues. **Spatial gallery:** `ContentView` shows a "最近作品" strip + full `ArcusGalleryView` sheet (tap reopens via reprocess), backed by `PhotoLibraryStore`. **Localization:** source language is **`en`** — write English literals in code (`Text("Recent")`, `String(localized: "Saved to Photos")`); `Localizable.xcstrings` provides the `zh-Hans` translations. Never hardcode Chinese in user-facing strings (the migration removed them all); developer NSLog/assert messages are plain English literals (not localized). Comments stay Chinese per convention. **Dark/light:** `Theme` colors are fully system-adaptive (`ink`/`ink2`/`title`/`body`/`sub`/`faint`/`surface`/`hairline` via dynamic `UIColor`); the app follows the system appearance for chrome (home/gallery/settings/export) while the immersive 3D editor + processing screens force `.dark` (Apple-Photos-style media immersion). Use Theme tokens, not raw `.white`/`.black`, for adaptive surfaces. **Home is camera-first:** the top of `IdleView` is `CameraHomeCard` — an inline **live viewfinder** (not a fullScreenCover); scrolling down reveals the wordmark caption, recent works, 「From Your Library」 (Choose Photo / Use Sample), and the Rendering-Mode / Background-Fill settings. **Camera capture:** `CameraHomeCard` drives `CameraController` (`AVCaptureSession`/`AVCapturePhotoOutput`, a plain `NSObject`/`ObservableObject` with session work on a serial queue and `@Published` marshaled to main) + `CameraPreviewView`. Hardware depth is delivered on supported devices (LiDAR/dual/TrueDepth via `isDepthDataDeliverySupported`/`isDepthDataDeliveryEnabled` + `embedsDepthDataInPhoto`); the captured HEIC embeds depth and runs the **same** `AppModel.processData(Data)` path as a picked photo (`AuxDepthLoader` extracts + EXIF-orients the depth), unsupported devices fall back to estimated depth. The session starts/stops on the card's appear/disappear; no-camera/denied falls back to a guidance card over `HeroDepthPeel`. Privacy strings are English in `INFOPLIST_KEY_*` + localized via `InfoPlist.xcstrings` (zh-Hans). **Default sample:** `SampleImage.make()` returns the bundled vivid macaw photo (`SampleParrot` imageset, Unsplash-licensed, chosen for clean subject/background depth), falling back to a procedural gradient if absent. **Fog backdrop:** the Gaussian viewer's `gaussianBackdrop` + the processing screen render the source as a soft dreamy fog (heavy gaussian blur + gentle saturation + a `softLight` frosted veil + vignette, very subtle iridescence) so revealed/occluded areas read as mist, not a hard cut; the processing screen shows the photo at **original aspect** (`scaledToFit` card) over that fog. `HeroDepthPeel` (the 「深度分层」 vector illustration) is reused as the camera fallback visual. **App icon:** rainbow camera-aperture mark in `Assets.xcassets/AppIcon.appiconset` (single 1024 `AppIcon-1024.png`). **Tilt-reactive sheen:** `EditorView.gaussianSheen` reads `GaussianViewController.currentTilt()` (a cheap poll of `GaussianRenderer.lastOffset`, no per-frame `@Published`) inside a `TimelineView` to drift an iridescent highlight with the camera. **Stale-task guard:** `AppModel.activeRequestID` (UUID per process/repair) gates late results so a re-pick mid-process can't overwrite newer state.

### Core (`Arcus/Core/`)

`FloatImage` is the CPU pixel buffer the entire pipeline operates on — row-major `[Float]`, values ~0…1, `channels` 1 (depth/mask) or 3/4 (color), with `cropped`/`resized`/`dilated`/sampling helpers. `MetalContext` (shared device/queue/library), `TextureIO`, `ImageUtils`, `SampleImage`, `AuxDepthLoader`. `PhotoLibraryStore` — on-device "3D photo library" under Application Support (source JPEG + thumb + meta, SHA256-keyed, capped/evicted), powering the spatial gallery; offline, photos never leave the device.

## Cross-file invariants (easy to break silently)

- **`MeshUniforms` must have identical memory layout in Swift (`ParallaxRenderer.swift`) and Metal (`Shaders.metal`).** Fields are commented with byte offsets (`offset 0` … `fgCenter` at 48, stride 56). When you add/reorder a field, update both and verify with `MemoryLayout.offset(of:)` — a mismatch corrupts rendering with no compile error.
- **Robustness fallbacks are load-bearing**, not optional polish — every stage (depth, segmentation, each inpainter) degrades instead of crashing. Preserve that when editing.

## Conventions

- **Comments are in Chinese; identifiers in English.** Match the surrounding density and idiom when editing.
- No new third-party dependencies — system frameworks only (SwiftUI, Vision, CoreML, Metal, MetalPerformanceShaders, CoreMotion, AVFoundation, ImageIO, Photos).
- Don't commit models; `Arcus/Resources/*.mlpackage/` is gitignored and bundled automatically by Xcode at build time.

## Docs (`docs/` — gitignored, local-only; absent on fresh clones)

Only `09`–`17` are present in this checkout; the early-research/superseded-architecture notes `01`–`08` have been retired (if a fresh clone needs them, they're gone — don't go looking). Present docs: `09-fill-research-v2.md` (disocclusion-fill research), `10-edge-antialiasing.md` (silhouette-AA root-cause + fix), `11-spatial-reframe.md` (the 「重拍」 mode), `12-industry-2d-to-3d-onepager.md` (transcribed industry survey — Apple/PICO/Meta/Samsung/XReal 2D→3D, the disparity math, on-device depth), `13-naked-eye-3d-from-ios26.md` (transcribed first-principles explainer — disparity↔depth geometry, autostereograms, single-image depth, gyro parallax, fg/bg black-frame video + temporal-consistency & segmentation gotchas), `14-tech-share-2d-to-3d.md` (tech-share narrative draft — fact-checked 2024–2026 industry timeline through WWDC26 Spatial Reframing, with Arcus as the running demo), `15-frame-pop-out.md` (the 「出框」 frame-bars feature: rationale, draw-order design, trade-offs), `16-openreshot-research.md` (OpenReshot 3DGS+SHARP+Gemini competitive teardown — why on-device splatting beats it), `17-gaussian-splatting.md` (the Gaussian Splatting render mode: builder, EWA rasterizer, repair, lens dock — §10 covers the viewer additions). Trust the source tree above over any stale module list inside these notes.
