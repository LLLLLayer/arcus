# 09 — Fill research v2: the 2024H2–2026 frontier (2026-06-08)

> Second multi-agent research pass (49 agents, **41 methods, 36 net-new**), scoped to what is *new* since
> `docs/08` and explicitly asking: **is anything newer/better than the planned MI-GAN fill?** Adversarially
> verified (recency + on-device + artifact lenses).

## Bottom line

**No 2024H2–2026 method beats MI-GAN as the next thing to build** for Arcus's actual open problem — a clean,
controllable, *small*, license-clean, on-device fill that produces a good **thin band at depth cliffs**. Every
newer contender fails at least one hard constraint *today*. **Build MI-GAN next** (opt-in HQ band-fill).

But two findings are strategically important and reshape the long game:

1. **Apple now ships Arcus's exact headline feature on-device** (iOS 26 "Spatial Scenes").
2. **The real representation upgrade is feed-forward single-image 3D Gaussian Splatting** — but it's not
   shippable yet and, notably, **doesn't invent occluded content**.

## The three net-new clusters (all blocked today)

### 1. Apple Spatial Scenes / `Spatial3DImage.generate()` — the biggest signal, not usable inside Arcus
`RealityKit.ImagePresentationComponent.Spatial3DImage(contentsOf:) + generate()` turns one 2D photo into a
parallax "spatial scene" with **on-device generative AI that invents occluded content** — exactly Arcus's
pitch, shipped by Apple, 0 MB to the app, no weights, no license burden.
- **Blocker A — not callable from iOS:** the developer `generate()` API is verified **visionOS-26-only**. The
  iOS 26 *iPhone* Spatial Scenes is a closed **Photos-app feature** with no public API (runs on iPhone 12+ on
  the Neural Engine, so the model is reachable by the OS — just not by third-party iOS apps).
- **Blocker B — black box:** even where callable, `generate()` returns a RealityKit component, **not** a depth
  map / mesh / filled pixels you can extract. Zero thin-band control (can't apply our depth-gated fill, 1px
  tonal-match, or background-only sourcing); adopting it means **replacing Arcus's whole Metal mesh+fill
  pipeline** and raising the floor to iOS 26.
- **Verdict: WATCH.** Re-check the `@available` badge on `Spatial3DImage.generate()` at **every Xcode/WWDC
  drop**. If Apple ever exposes it on iPhone, it becomes a free, high-quality alternate "Apple Spatial Scene"
  render mode. It is also the **quality bar** to beat.

### 2. Feed-forward single-image → 3DGS (Apple SHARP, Flash3D, MLGS) — the long-horizon representation axis
This is the "fundamentally better representation" direction (replace depth-mesh+fill with predicted Gaussians /
multi-layer LDI of primitives). Genuinely the future, but:
- **SHARP** (Apple, "<1s monocular view synthesis"): **702M params / 2.81 GB**, `apple-amlr` **research-only**
  license, needs a hand-written **Metal Gaussian rasterizer** — and **explicitly does not synthesize unseen
  content** ("renders nearby viewpoints, rather than synthesizing entirely unseen parts"), so it doesn't even
  answer the "invent the band" question.
- **Flash3D / MLGS** (multi-layer offset-Gaussian LDI): **CC BY-NC / no weights**, UniDepth ViT-L backbone =
  large. Validates Arcus's multi-layer instinct (carry hidden background as its own layer of primitives) but
  not shippable.
- **Verdict: WATCH + maybe prototype.** The single most valuable *internal* R&D bet: re-implement **SHARP's
  2-layer-Gaussian head + perceptual/Gram-on-novel-views recipe** as a *small student trained on permissive
  data* (do **not** ship Apple's weights). With a generative/perceptual loss on the occlusion layer, this is
  the only path that both upgrades the representation **and** starts to truly invent band content — which
  neither MI-GAN nor any shippable 3DGS method does today.

### 3. Few-step / distilled diffusion inpainters (TurboFill, MobileDiffusion, ViewCrafter/FVGen) — wrong fit
- **No shippable weights / license:** MobileDiffusion weights deliberately never released; TurboFill is
  SDXL-scale (multi-GB, no weights/permissive license); RETHINED's repo is verified (mid-2026) to be a Jekyll
  **website with zero checkpoints and no license** despite being the ideal-on-paper fit (4.3M-param
  non-generative patch CNN, Core ML export claimed).
- **Wrong artifact profile:** free-running generative priors **hallucinate content and shift tone in a thin
  band** — the exact LaMa failure class Arcus already rejected.
- **Verdict: REJECT now; RETHINED = WATCH** (revisit only if real weights + a permissive license appear).

## Why MI-GAN still wins

It's the only candidate that clears every hard constraint at once: **5.95M params (~7–15 MB Core ML FP16)**,
**MIT** with **actually-released weights + pre-converted ONNX on HF**, **on-device-proven ~296 ms@256 on A16**
(well inside the ~10 s opt-in budget, far faster than today's ~10 s CPU PatchMatch), **not text-conditioned**
(can't hallucinate semantic garbage), and a **drop-in for where Arcus already runs LaMa/PatchMatch** — so it
inherits the existing safety architecture (depth-gated background-only sourcing, `mask>0.5` composite, 1px ring
tonal-match) that kills the color cast which got LaMa rejected.

## Recommended plan

### Build next — MI-GAN as opt-in HQ band-fill
1. Convert `andraniksargsyan/migan` (`migan_pipeline_v2.onnx`, Places2 512) → Core ML FP16 `.mlpackage`
   (coremltools onnx→CoreML, or torch→coremltools fallback); then test 6-bit palettization to shrink the
   bundle. Reuse the `scripts/download_models.sh` + `.mlpackage` bundling flow.
2. Wire as an alternate branch inside `DisocclusionInpainter` alongside `patchMatchFill`, gated by the existing
   `Options.highQualityFill`. **Crop to the disocclusion-band bbox + small margin** (reuse the
   `ringRadiusFraction=0.045` band geometry) so MI-GAN runs near-native res on a small crop, not the full frame.
3. Feed band crop + `mask=hole`; composite back **only `mask>0.5`** (reuse the halo-fix `inpaintBin = mask>0.5`
   rule — never dilate into real background).
4. Keep the **depth-gating from PR #2** (trust MI-GAN only where it agrees with background-side context) and
   keep `verticalFill+depth` as the always-on fallback on the thinnest seams.
5. Add the **1px background-ring tonal match** (the `neutralizeColorCast` trick already in `LamaInpainter`) to
   guarantee no seam/color cast.
6. Validate offline (the near-object-above-hole harness from PR #2), then **device A/B via iVista**:
   verticalFill vs PatchMatch vs MI-GAN on real portraits at max parallax — check band color cast, seams,
   hallucinated structure.

**Risks:** trained on Places2/FFHQ → can soften texture / invent mild structure in *wide* holes (mitigate by
restricting to the thin band crop + copy-fill fallback); ONNX→CoreML op/dynamic-shape snags (budget a day, pin
input res); it **doesn't change the representation**, so beyond ~±5% parallax the band can outgrow any 2D fill
(the real ceiling → see the 3DGS watch); bundle-size creep (palettize, keep opt-in).

### Do in parallel (cheap, complementary, near-zero risk)
- **SLIDE-style soft-alpha** Metal pass (`α = exp(−σ‖∇D‖²)`) to soften the depth-cliff cut → reduces the band
  magnitude the fill must cover and avoids hard-edge artifacts at larger parallax.
- **Keep foreground/mid scale (#1) + depth-gated copy-fill (#2) as the always-on <1 s default;** MI-GAN stays
  strictly opt-in HQ behind them, copy-fill as fallback.

### Long-horizon watch
- **Prototype the SHARP-style 2-layer-Gaussian student** on permissive data — the only path that upgrades the
  representation *and* invents band content.
- **Re-verify Apple `Spatial3DImage` iOS availability every SDK/WWDC** — the one external lever that could
  leapfrog the whole pipeline.

## Method tally
41 methods surfaced (36 net-new), 14 deep-read + adversarially verified. Rankings: MI-GAN = build-next;
SHARP-recipe = long-horizon prototype; Apple Spatial3DImage = watch (re-check iOS); Flash3D/MLGS = watch
(non-commercial); RETHINED = watch (no weights/license); TurboFill/MobileDiffusion/ViewCrafter = reject.
