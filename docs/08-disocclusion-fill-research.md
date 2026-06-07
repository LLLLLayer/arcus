# 08 — Disocclusion / boundary-completion research (2026-06-08)

> Multi-agent research workflow (49 agents): 6 search angles → 43 distinct methods → 14 deep-read →
> adversarial verify (feasibility + artifact lenses) → ranked synthesis for Arcus's on-device constraints.
> Outcome: two **adopt** wins shipped tonight on `feat/depth-gated-fill`; a neural roadmap kept on file.

## The one principle that matters

Every fill artifact Arcus has hit (LaMa magenta cast, push-pull blur, jump-flood pinwheel, vertical streaks) is
a symptom of the fill **sampling the wrong pixels**. The disocclusion band is, by definition, *the background
that the subject was occluding*. So the fill must take color **only from the background, at the background's
depth** — never from the subject edge, never from a nearer object. Arcus already has the disparity map; it just
wasn't being used by the fills. Everything below is a corollary of "fill the band from background only."

## Ranked decision (for Arcus)

| Method | Verdict | Why / next step |
|---|---|---|
| **Depth-gated vertical/nearest fill** (DIBR; Daribo'11, Jain) | **ADOPT — default tier** | Zero model. Gate `verticalFill` seeds to background-side disparity. **Shipped.** |
| **Depth-aided exemplar PatchMatch** (Daribo-Saito; Gautier/Le Meur) | **ADOPT — HQ tier** | Zero model. Restrict PM sources to background, add depth-SSD. **Shipped.** |
| **MI-GAN** (ICCV 2023, Picsart) | PROTOTYPE — next HQ step | MIT, 5.95M params, ~28MB ONNX→~7-15MB CoreML FP16; **296 ms @256px on A16**. ONNX on HF → coremltools ~1-day path. Use band-bbox crop, opt-in HQ, *not* default. |
| **SLIDE soft-alpha** (ICCV 2021, Google) | PROTOTYPE — the cheap half only | Soft foreground alpha `A = exp(−σ·‖∇D‖²)` needs **no model** — a Metal pass over the depth gradient; softens the silhouette cut. (Its DeepFill inpainter is CC-BY-NC + no weights → skip.) |
| **RETHINED / NeuralPatchMatch** (WACV 2025) | WATCH | Best on-device *fit* (4.3M params, **17.6 ms @1024 on M2**, repo is Core ML-first: ships im2col/col2im workarounds). Non-generative patch-copy → no color cast. Blocked: **repo has no LICENSE, no released weights.** Monitor. |
| **One-Shot 3D / Farbrausch** (Meta SIGGRAPH 2020) | WATCH — blueprint only | The *idea* is gold: a tiny PartialConv U-Net whose convolutions aggregate over the **LDI connectivity graph**, so the receptive field physically cannot cross the depth cliff → structurally no foreground bleed. But: weights unreleased, Caffe2go dead, the load-bearing op is a custom per-pixel BFS gather. Keep as design north-star, don't port. |
| CheapNVS (Samsung 2025) | REJECT | One-pass NVS that would *replace* Arcus's whole mesh-warp pipeline, not augment it. |
| Depth-adaptive push-pull (HHF) | REJECT | Depth-gated version of the push-pull we already rejected as blurry; patent-encumbered. |

## What shipped tonight (`feat/depth-gated-fill`, PR #2)

Both changes thread the already-computed `disparity` into the existing CPU fills — no model, no download, no
color-shift risk, behind the existing default/HQ split.

### Default tier — depth-gated `verticalFill`
Mark "background-side" valid pixels (`disp ≤ median(bg) + ε`). Prefer them as the vertical seed; a column with
no background seed falls back to any valid pixel (so the fill never leaves a hole). This fixes the case where a
**near object directly above the band** gets copied down into it.

### HQ tier — depth-aided PatchMatch
1. **Source gating:** a patch may only be a source if its center is background-side (`disp ≤ median(bg)+ε`).
   Fallback to ungated if <64 sources survive (prevents tiling).
2. **Depth-SSD term:** patch cost gains `β·(D_target − D_source)²`. `D_target` is a **background-filled** depth
   (push-pull) so a hole pixel reads as *the depth behind the subject*, not the subject's near depth — otherwise
   the hole's near disparity would reject the very far-background sources we want. Matches now prefer texture at
   the same depth as the local background.
3. Depth-gated `verticalFill` is also the PM initialization.

**Verification:** offline harness with a near (red) object directly above a hole over far (green) background —
ungated vertical fill pulls red into 3/5 band rows `(0.45, 0.45, 0)`; gated fill is pure background `(0, 1, 0)`;
gated PatchMatch likewise, no NaN. Builds clean (Debug, iOS Simulator).

## Roadmap (deferred, needs explicit go-ahead)

1. **MI-GAN as the HQ neural fill.** MIT, mobile-proven on A16, clean ONNX→Core ML path. Run on a **cropped
   band bounding-box at low res** (the band is thin; full-frame 256px = 296 ms, a crop is far less), opt-in HQ.
   Guardrail against the LaMa trap: still composite only inside the disocclusion mask, and tonally match the
   filled band to a 1-px ring of real background (the "luma/chroma match" finishing pass — cheap, model-agnostic).
2. **SLIDE soft-alpha** as a Metal pass to feather the silhouette cut (orthogonal to fill; composes with
   foreground-scale from `docs/07`).
3. **RETHINED** — revisit if/when it gets weights + a license.

These compose with **foreground-scale** (`docs/07`): scale **hides** most of the band; a depth-aware fill
**cleans up** what still peeks. Do the cheap geometry first, reach for a neural fill only for the residual.
