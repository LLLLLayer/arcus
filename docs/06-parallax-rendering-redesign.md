# 06 — Parallax Rendering Research & Redesign (2026-06-07)

> Deep research (6 parallel agents) + synthesized blueprint + adversarial critique.
> Goal: eliminate the two device-reported artifacts — the **wide halo/smear** (2-plane path) and the **onion-ring banding** (MPI path).

## Synthesized blueprint

I now have full grounding in the actual code. Here is the blueprint.

---

# Arcus Parallax Blueprint: Continuous Depth-Grid Forward-Warp + 2-Layer Soft-Alpha LDI

## 1. Decision: representation & render method

**Primary: a continuous per-pixel depth-grid triangle mesh, forward-warped in the vertex shader, with depth-cliff triangle cutting, over a single inpainted background layer; the foreground silhouette composited with a SOFT alpha (SLIDE-style `A = exp(−β‖∇D‖²)` folded with the subject matte).** Two draws: (1) full uncut background mesh using inpainted `bgColor`/`bgDepth`; (2) cut foreground mesh using original RGBA + per-pixel `depth`, alpha-blended over it.

**Why this kills BOTH artifacts:**

- **Onion-ring banding (Path B) is a *quantization* artifact** of representing continuous depth as a few discrete planes with hard boxcar membership (MPI angle: "banding is a quantization artifact of discrete α and discrete depth"; SLIDE angle: identical conclusion). A per-pixel mesh displaces *every vertex by its own continuous disparity* — there are no plane indices to quantize, so iso-depth contours never appear. The MPI dossier's own verdict is that 32–64 raw planes are "too heavy to render live" on A-series and the right move is a continuous-depth mesh; the soft-layering and DIBR angles both independently land on the same mesh.

- **Halo/smear (Path A) has two roots, both removed.** (a) The flat-sticker foreground reveals a band because it has a single depth — the per-pixel mesh gives *continuous parallax inside the subject*, so no cardboard cutout. (b) The wide blurry aura is caused by `ringRadiusFraction = 0.045 × longside` dilation (≈29 px at 640) fed to LaMa. The narrow-disocclusion angle proves the real disoccluded band is only `parallax × (d_front − d_back)` ≈ a *handful of pixels*; we replace the fat silhouette dilation with an edge-localized one-sided band. The rubber-sheet smear that a naive single mesh would produce is cut away (DIBR angle: "break all edges with large differences and remove those triangles"), and the soft alpha feathers the silhouette so there is no 1-px color fringe (narrow-disocclusion + SLIDE: composite `A·F + (1−A)·bg`).

This is exactly the convergent production recipe (apple-products + ldi-3dphoto + dibr-mesh): *monocular depth → depth-edge-aware mesh with soft alpha at discontinuities → narrow inpainted disocclusion → bounded gyro parallax.* It is the One-Shot-3D-Photography render strategy (cut mesh + 2 layers) minus the heavy on-device inpaint, which we already cover with LaMa.

**Fallback:** if mesh/index buffers are too invasive for v1, keep the full-screen-triangle fragment path but switch `mpi_fragment` from hard boxcar to a **backward iterative warp** (relief-march the per-pixel `depth` texture, DIBR angle §2) — continuous parallax with zero geometry. It is one shader change but costs per-pixel ALU and can swim under-sampled, so it is the fallback, not the primary.

## 2. Exact algorithm

### CPU pipeline (one-time, in `Photo3DPipeline.process`)

Everything below runs on `FloatImage` (`FloatImage.swift`). Keep depth/disparity convention `1=near, 0=far`.

**(a) Disparity sharpen.** Replace the current `boxBlurred(radius: W/350)` blur with an **edge-preserving** pass so depth edges stay crisp. Add a separable weighted-median / bilateral to `FloatImage` (5×5, disparity σ≈0.2, per ldi-3dphoto Kopf recipe). Cheap interim: keep `boxBlurred` only for despeckle but run it at radius 1, then a 3×3 median. This sharpening is the single highest-value depth step (ldi + narrow-disocclusion).

**(b) Depth-edge detection.** Compute Sobel `∇D` on `disparity` → magnitude `g`, direction. Edge set `g > τ_edge`. Connected-component label, drop segments < 10 px (kill flying pixels). Store `g` and gradient as `FloatImage`s; you will reuse `g` for the soft alpha and for band width.

**(c) NARROW disocclusion mask** (replaces lines 78–83, the fat `dilated(radius: ringRadius)`):
- Max pixel parallax `P_max = parallaxAmp × max|offset| × imageLongSide` (a few % → ~6–24 px at 1024).
- For each edge pixel, band thickness `w_px = clamp(round(P_max × (d_front − d_back)), 2, 8)`, where `d_front`/`d_back` are the high/low disparity neighbors across the edge.
- Grow the mask **one-sided**, only down-gradient (toward the *far* side, `sign(∇D·anyParallaxDir)`), by `w_px`, **stopping at the subject silhouette**. Because gyro parallax is bidirectional, take the band on *both* sides of strong edges but still only the far side of each edge — i.e. dilate the far side, never the whole silhouette. Result `B_mask`: a thin one-sided ribbon, not a blob. This is the core fix for the halo.

**(d) Background COLOR inpaint (sharp).** Reuse `LamaInpainter.inpaint(rgb:hole:)` but pass `B_mask` (the thin ribbon) as `hole` instead of the dilated silhouette. The existing bbox-crop + 512 native-res + `neutralizeColorCast` logic already does the right thing (narrow-disocclusion: "crop tight, inpaint at native res, paste back" → sharp). Smaller mask ⇒ LaMa copies neighbors instead of hallucinating ⇒ no blur. Keep push-pull as the existing fallback.

**(e) Background DEPTH inpaint (far-side).** Today `bgDepthImg = pushPullFill(disp, valid)` diffuses front depth into the hole (creates a ramp). Change: fill `B_mask` with **far disparity only** — set hole disparity by one-sided flood/push-pull seeded *exclusively from the down-gradient (far) neighbors*, clamped to `≤ d_back + ε`. Practically: build `valid` that marks foreground-side pixels as INVALID seeds too, so push-pull pulls only from background. Flat far depth, hard step at the edge (narrow-disocclusion §2). The BG mesh must sit *behind* the FG.

**(f) Crisp subject matte.** Keep `VNGenerateForegroundInstanceMask` + the existing `guidedRefined` (good — guided feather recovers hair). Additionally bake the **soft visibility** there: compute `A_edge = exp(−β·g²)` and store the *foreground composite alpha* as `fgAlpha = matte · A_edge` into the fg RGBA's A channel (replaces `fg.pixels[p*4+3] = mask` at line 112). This is SLIDE's `A' = A·matte`, feathering the silhouette so warping never produces a color fringe.

**(g) Bake textures.** Unchanged set, but `fgColor.a` now carries `fgAlpha`; `bgDepth` now carries far-filled depth; the `depth` texture (per-pixel disparity) is now the *primary* geometry source for the FG mesh. `fgPlaneDepth`/`bgPlaneDepth` become vestigial (drop from `Photo3DScene` once mesh path is default).

### GPU render (mesh, in `ParallaxRenderer` + `Shaders.metal`)

**Mesh construction (one-time, on scene bake).** Build a vertex grid at **stride K=2 px** (≈262 k verts at 1024×720; fine for A-series). Per vertex store only `(u,v)` in clip-grid order — disparity is *sampled in the vertex shader* from the `depth`/`bgDepth` texture, so no per-vertex disparity buffer is needed and the same vertex/index buffers serve both layers. Build **two index buffers**:
- **BG index buffer:** full grid, all quads (no cuts) — the inpainted background is a complete surface.
- **FG index buffer:** emit a quad's two triangles only if `max−min` of the 4 corner disparities `≤ τ_cut`. Build it in a compute kernel (DIBR angle `buildIndices`) sampling `depth`, or on CPU once. Dropped cliff quads leave the silhouette gap through which the BG shows.

Store both in `Photo3DScene` (add `vertexBuffer`, `fgIndexBuffer`, `fgIndexCount`, `bgIndexBuffer`, `bgIndexCount`, `gridW`, `gridH`).

**Vertex displacement math.** Disparity drives a pure screen-space shear (DIBR angle):
`shearedUV = uv + offset · parallaxAmp · (d − depthPivot) · layerFactor`
where `d` is sampled disparity, `layerFactor = 1` for FG and `bgParallaxFactor` for BG. Write `d·depthScale` to the z/depth output so nearer fragments win the depth test (FG occludes BG correctly). Keep the existing `coverScale`/`imageUV` overscan mapping.

**Composite.** Draw BG mesh first (opaque, depth-write), then FG mesh with `srcAlpha / 1−srcAlpha` blend and depth-test `less`. The FG fragment samples `fgColor` and multiplies by the baked soft `fgAlpha`; cut cliffs reveal inpainted BG; feathered alpha kills the fringe → `out = A·fg + (1−A)·bg`.

**Uniforms.** The current `ParallaxUniforms` (stride 56) already carries `offset, coverScale, parallaxAmp, bgParallaxFactor, depthPivot, flatten, debugMode`. Add `depthScale: Float` and `layerFactor: Float` (set per draw); drop the MPI band/plane fields once legacy paths are removed. Keep `debugMode` (sample depth/matte/bg directly in the FG vertex/fragment for visualization).

## 3. Metal shader pseudo-code + Swift encoder

```metal
struct MeshUniforms {            // replaces ParallaxUniforms once legacy removed
    float2 offset; float2 coverScale;
    float  parallaxAmp; float depthPivot; float flatten;
    float  layerFactor;          // 1.0 FG, bgParallaxFactor BG
    float  depthScale;           // maps disparity → clip z
    int    debugMode;
};
struct VOut { float4 pos [[position]]; float2 uv; float alpha; };

vertex VOut mesh_vertex(uint vid [[vertex_id]],
                        const device float2* gridUV [[buffer(0)]],
                        constant MeshUniforms& u    [[buffer(1)]],
                        texture2d<float> dispTex    [[texture(0)]],
                        texture2d<float> fgColorTex [[texture(1)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 uv0   = gridUV[vid];
    float2 imgUV = 0.5 + (uv0 - 0.5) * u.coverScale;
    float  d     = dispTex.sample(s, imgUV).r;
    float2 off   = u.offset * u.parallaxAmp * (1.0 - u.flatten) * u.layerFactor;
    float2 warped = imgUV + off * (d - u.depthPivot);
    VOut o;
    o.pos   = float4(warped * float2(2,-2) + float2(-1,1), (1.0 - d) * u.depthScale, 1);
    o.uv    = imgUV;
    o.alpha = (u.layerFactor < 1.0) ? 1.0           // BG opaque
                                    : fgColorTex.sample(s, imgUV).a;  // baked matte·exp(-β g²)
    return o;
}

fragment float4 mesh_fragment(VOut in [[stage_in]],
                              texture2d<float> colorTex [[texture(0)]],
                              constant MeshUniforms& u  [[buffer(1)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float4 c = colorTex.sample(s, in.uv);
    if (u.debugMode == 1) { float d = c.a; return float4(d,d,d,1); } // etc.
    return float4(c.rgb * in.alpha, in.alpha);   // premultiplied for over-blend
}
```

The depth-cliff cut is the `buildIndices` compute kernel from the DIBR dossier (sample `depth`, emit 6 indices per quad only if `spread ≤ τ_cut`), run once at bake.

**Swift encoder** (`ParallaxRenderer.encodeMesh`, replacing `encodeLegacy`/`encodeMPI`):
```swift
enc.setRenderPipelineState(meshState)        // depthState: less, write on
enc.setVertexBuffer(scene.vertexBuffer, offset: 0, index: 0)
// --- BG: full mesh, opaque, layerFactor = bgParallaxFactor ---
var ub = u; ub.layerFactor = params.bgParallaxFactor
enc.setVertexBytes(&ub, length: ..., index: 1)
enc.setVertexTexture(scene.bgDepth, index: 0)
enc.setVertexTexture(scene.bgColor, index: 1)   // alpha unused (opaque)
enc.setFragmentBytes(&ub, length: ..., index: 1)
enc.setFragmentTexture(scene.bgColor, index: 0)
enc.drawIndexedPrimitives(type: .triangle, indexCount: scene.bgIndexCount,
    indexType: .uint32, indexBuffer: scene.bgIndexBuffer, indexBufferOffset: 0)
// --- FG: cut mesh, soft-alpha over ---  (meshStateBlend: srcAlpha/1-srcAlpha)
enc.setRenderPipelineState(meshStateBlend)
var uf = u; uf.layerFactor = 1.0
enc.setVertexBytes(&uf, length: ..., index: 1)
enc.setVertexTexture(scene.depth, index: 0)
enc.setVertexTexture(scene.fgColor, index: 1)
enc.setFragmentBytes(&uf, length: ..., index: 1)
enc.setFragmentTexture(scene.fgColor, index: 0)
enc.drawIndexedPrimitives(type: .triangle, indexCount: scene.fgIndexCount,
    indexType: .uint32, indexBuffer: scene.fgIndexBuffer, indexBufferOffset: 0)
```
Note this swaps the **full-screen triangle** (`drawPrimitives vertexCount: 3`) for **indexed mesh draws**, and moves depth sampling into the *vertex* stage. A `MTLDepthStencilState` (currently absent — the view has no depth attachment) must be created, and `MTKView.depthStencilPixelFormat = .depth32Float` set in `ParallaxMetalView`.

## 4. Parameter recommendations

| Parameter | Value | Source / rationale |
|---|---|---|
| Mesh stride K | 2 px (≈260k verts @1024) | DIBR: full-res fine on A-series; K=2 halves bandwidth |
| `τ_cut` (FG quad disparity spread) | 0.04–0.06 (norm disparity) | ldi τ_disp≈0.05; DIBR "few disparity units" |
| `τ_edge` (depth-edge detect) | top ~3% of `g`, or 0.05 | narrow-disocclusion |
| Disocclusion band width | `clamp(P_max·(d_f−d_b), 2, 8)` px | narrow-disocclusion: band = parallax×Δdisp |
| `ringRadiusFraction` | **delete** (was 0.045 → fat halo) | replaced by per-edge band |
| `β` (soft alpha `exp(−β g²)`) | tune so alpha ramps over 3–8 px | SLIDE Eq.1 |
| Matte guided-filter radius | keep `max(2, W/150)`, eps 2e-4 | already good (hair) |
| `parallaxAmp` | keep 0.06 default | small bounded gyro parallax |
| `depthScale` | ~0.5 (disparity 0..1 → clip z) | keep FG strictly in front of BG |
| LaMa crop margin | keep 0.35× bbox | LamaInpainter already native-res |

## 5. Implementation checklist (dependency-ordered, each testable)

1. **Add depth attachment.** Set `depthStencilPixelFormat = .depth32Float` in `ParallaxMetalView`; create `MTLDepthStencilState(less, write)`. Test: legacy full-screen path still renders (depth ignored).
2. **Add `bilateralSharpen`/`median3x3` to `FloatImage`**; swap into pipeline step (a). Test: depth-debug view (`debugMode==1`) shows crisper edges, no block artifacts.
3. **Sobel `∇D` + edge map** in pipeline; expose as a debug texture. Test: visualize edges hug silhouette.
4. **Narrow one-sided `B_mask`** (step c), replacing lines 78–83. Test: dump `B_mask` — thin ribbon on far side only, not a fat ring.
5. **Far-side depth fill** (step e). Test: `bgDepth` debug shows flat far depth in band, hard step at edge (no ramp).
6. **Feed `B_mask` to LaMa** (step d). Test: `bgColor` debug — sharp background texture in the thin band, no wide blur.
7. **Bake soft `fgAlpha = matte·exp(−β g²)`** into `fgColor.a` (step f). Test: matte debug shows feathered (not binary) silhouette.
8. **Build vertex grid + two index buffers** (compute cut kernel) in scene bake; add fields to `Photo3DScene`. Test: log `fgIndexCount < bgIndexCount` (cliffs dropped).
9. **Add `mesh_vertex`/`mesh_fragment` + pipelines** (`meshState` opaque, `meshStateBlend` over). Test: render BG mesh alone — full image, parallax shears smoothly.
10. **FG cut mesh over BG** via `encodeMesh`. Test: at offset=0 output == original; tilt → smooth continuous parallax inside subject, narrow clean disocclusion, no rings, no halo.
11. **Wire `debugMode`, gyro/pan, offscreen export** through `encodeMesh`; delete `encodeLegacy`/`encodeMPI`, `mpi_fragment`, `parallax_fragment`, and `layerCount` UI. Test: export video matches live.
12. **Perf pass.** Confirm 60 fps in **Release** (per your memory note: Debug is misleadingly slow). Reduce K to 3 if vertex-bound.

## 6. /docs note

```markdown
# Arcus — Parallax 3D Rendering Approach

## Problem
Two render paths each produced an artifact:
- **2-plane rigid (Path A):** a flat foreground "sticker" + one rigidly-shifted
  inpainted background. Produced a wide washed-out HALO around the subject —
  caused by (1) single-depth foreground (cardboard cutout, no internal parallax)
  and (2) a disocclusion hole made by dilating the whole silhouette by ~4.5% of
  the long side, then inpainting it blurry at low res.
- **MPI bands (Path B):** N=2..6 discrete depth planes with hard boxcar
  membership. Produced ONION-RING / stair-step contours — the classic
  quantization artifact of representing continuous depth with too few hard planes.

## Research findings (6 angles)
- **MPI lineage:** banding is a *quantization* artifact of discrete α + discrete
  depth; dense 32–64 planes fix it offline but are too heavy to render live on
  A-series. Bake down to continuous depth instead.
- **SLIDE / soft layering:** replace the binary silhouette with a continuous
  soft alpha `A = exp(−β‖∇D‖²)` folded with the subject matte; composite
  `A·fg + (1−A)·bg`. Removes rings AND fringe in one move.
- **LDI / 3D-Photo-Inpainting / One-Shot:** detect depth edges by disparity,
  CUT mesh connectivity along them (anti-rubber-sheet), inpaint color AND depth
  behind edges; ship a single cut textured mesh — continuous geometry =
  continuous parallax.
- **Narrow disocclusion:** the real disoccluded band is only
  `parallax × (d_front − d_back)` ≈ a few px — NOT a fat silhouette dilation.
  Inpaint a thin one-sided ribbon at native res (sharp); fill its depth from the
  far side (flat, no ramp).
- **DIBR / mesh-warp:** forward depth-grid mesh + per-quad cliff cut is the
  robust, GPU-cheap choice for small parallax; feather the cut edge by 1 px.
- **Apple / products:** the shipping bar (Spatial Scenes / Lock-Screen) is
  bounded gyro parallax + soft edges + good matte; heavy inpaint is optional.

## Chosen approach
A continuous **per-pixel depth-grid mesh, forward-warped in the vertex shader**,
with **depth-cliff triangle cutting**, drawn over a **single inpainted-background
mesh**, the foreground composited with a **soft alpha** (matte · exp(−β‖∇D‖²)).
The disocclusion is a **thin, edge-localized, one-sided band** (≤8 px) inpainted
sharply by LaMa with far-side depth fill.

- Continuous per-vertex disparity ⇒ no plane indices ⇒ **no onion rings**.
- Cliff cut + soft alpha + thin far-side band ⇒ **no rubber-sheet, no wide halo,
  no edge fringe**; subject gets real internal parallax (no cardboard cutout).

## Rejected alternatives
- **Dense 32–64-plane MPI at render time:** 256–512 MB textures + N full-screen
  alpha layers — fails the 60fps / mobile-memory budget.
- **Keep 2 hard planes / boxcar membership:** the cause of banding; non-starter.
- **Single uncut depth mesh:** rubber-sheet smear across every depth cliff.
- **Backward iterative (relief-march) warp:** continuous but per-pixel ALU heavy
  and can swim under-sampling at small parallax — kept only as a no-geometry
  fallback.
- **Fat silhouette dilation + low-res LaMa:** the direct cause of the Path-A
  halo; replaced by the narrow per-edge band.
```

**Key files touched:** `Arcus/Rendering/Shaders.metal` (new `mesh_vertex`/`mesh_fragment`, delete `parallax_fragment`/`mpi_fragment`), `Arcus/Rendering/ParallaxRenderer.swift` (new `encodeMesh`, depth state, delete legacy/MPI encoders), `Arcus/Rendering/ParallaxMetalView.swift` (depth attachment), `Arcus/Pipeline/Photo3DPipeline.swift` (steps a–g: sharpen, edge detect, narrow band, far-depth fill, soft alpha bake), `Arcus/Pipeline/Photo3DScene.swift` (add vertex/index buffers + grid dims), `Arcus/Core/FloatImage.swift` (add bilateral/median sharpen, Sobel gradient, one-sided band grow), `Arcus/Pipeline/LamaInpainter.swift` (unchanged API; now fed the thin band).

## Adversarial critique (7 required changes)

The blueprint's claims check out: the metal view has no depth attachment, `FloatImage` has `dilated`/`boxBlurred`/`guidedRefined` but no bilateral/median/Sobel/one-sided-grow, the renderer uses a full-screen triangle (no mesh/index buffers), and the pipeline does the fat dilation at line 78-81 with `ringRadiusFraction=0.045`. I have enough grounding to deliver the critique.

---

# Adversarial Critique: Continuous Depth-Grid Forward-Warp + 2-Layer Soft-Alpha LDI

The diagnosis is correct and the direction is right. A continuous per-vertex mesh genuinely eliminates plane-quantization rings, and a thin one-sided band genuinely fixes the fat-halo root cause. But several mechanisms are over-stated, one is mathematically wrong, and the primary path is heavier than the doc admits. Verdict up front: **sound with 7 changes**.

## 1. Will it remove both artifacts?

**Onion rings: yes, robustly** — *provided mesh stride survives the perf pass*. The rings are pure plane quantization; per-vertex continuous disparity has no plane index to alias. The real risk is item-3 below in the checklist: "reduce K to 3 if vertex-bound." K=2→3→4 does *not* reintroduce banding (geometry stays continuous), but it **under-samples depth cliffs**, producing staircased silhouettes and triangle-scale shimmer on tilt. That's a different artifact, not rings — acceptable, but the doc should stop implying K is free.

**Halo: mostly, but two residual modes remain.**

- **(a) Black-gap leak at the cut.** The FG index buffer drops cliff quads; the BG mesh is supposed to show through. But the BG is drawn with `bgParallaxFactor < 1`, so at nonzero offset the BG shears *less* than the hole the FG cut opens. If the cut footprint ever exceeds the inpainted `B_mask` ribbon, you get raw clear-color (black) or stretched BG, not inpainted texture. The cut width (`τ_cut` over a 2px quad) and the band width (`P_max·Δd`, capped at 8px) are **computed independently** — nothing guarantees `band ≥ cut footprint`. This is the single biggest correctness gap (see §4).

- **(b) Soft-alpha re-blur.** `A = exp(−β‖∇D‖²)` feathers *every* depth edge, including the subject's true silhouette against background. With `over` blend and a non-inpainted-aligned BG, a 3–8px feather is exactly a faint halo again — milder than the 29px one, but the same family. SLIDE's soft alpha works because the BG behind it is correct; here it's `bgParallaxFactor`-sheared and only inpainted in the thin ribbon. Recommend β tuned to **2–3px**, not 3–8.

## 2. On-device feasibility

- **Mesh res / 60fps: fine.** 260k verts × 2 layers = ~520k vert invocations + ~1M triangles/frame. A-series eats this; vertex-stage texture sampling of `dispTex` is the only cost and it's one bilinear fetch. 60fps in **Release** is realistic (per memory note, never trust Debug).
- **Memory: fine.** Vertex buffer (2 floats × 260k = 2MB) + two uint32 index buffers (~6MB each). Trivial vs the existing model footprint.
- **CPU one-time ~1s: at risk.** The note says full pipeline is ~0.3–0.8s in Release. The blueprint *adds* per-pixel Sobel, connected-component labeling (drop <10px segments), bilateral/median, and **one-sided geodesic band-grow stopping at silhouette** — the last is not a separable filter and is the expensive one. Budget realistically ~0.4–0.8s *added*. Still acceptable for a one-time bake, but "tractable ~1s" is optimistic; do the band-grow at `inpaintSide` (640), not full res.
- **LaMa on thin band: sharp, but new failure mode.** A 2–8px ribbon is mostly copy-from-neighbor → sharp, good. But the existing `neutralizeColorCast()` (per memory: shifts hole-fill mean to the outside ring) needs ≥1 valid ring of pixels; an 8px hole with a 2px outside ring is statistically noisy → color-match may wander. Keep the cast-neutralize but widen its *sampling* ring independent of the (now tiny) hole.

## 3. Correctness risks in the math

- **Disparity convention is INVERTED in the shader.** Convention is `1=near`. Parallax shift must be **larger for near**. The pseudo-code writes `warped = imgUV + off*(d − depthPivot)` — correct sign (near moves more). But clip-z is `(1.0 − d)*depthScale`: with `d=1` (near) → z≈0, `d=0` (far) → z=depthScale. Metal default `less` passes **smaller** z. So near (z≈0) wins — **correct**, but *only* if depth range is [0,1] and you never clamp. Verify `depthScale ≤ 1` or near-plane clipping eats the subject. This is subtle and untested; add an assert/debug-z view.
- **Premultiplied blend mismatch.** Fragment returns `float4(c.rgb*alpha, alpha)` (premultiplied), but the encoder sets `meshStateBlend = srcAlpha / 1−srcAlpha`. Premultiplied color with a `srcAlpha` source factor **double-multiplies alpha** → dark fringes at the silhouette (the opposite of the halo, but still an edge artifact). Must be `sourceRGBBlendFactor = .one` (as the *existing* `mpiState` already correctly does). Copy that block.
- **`depthPivot` for BG.** BG samples `bgDepth` (far-filled) and shears by `layerFactor=bgParallaxFactor` around the *same* `depthPivot=0.5`. If far-fill is ~0.2 and pivot 0.5, the BG shears the *wrong direction* relative to FG at the pivot crossover. Keep pivot consistent but verify BG never crosses FG depth.
- **Occlusion vs cut redundancy.** With depth-test on AND cut mesh AND soft alpha, three mechanisms fight at the silhouette. Depth-test `less` + over-blend is order-dependent; drawing BG-then-FG opaque-then-blend is fine, but the FG's *feathered* alpha fragments still write depth — feathered pixels at z≈near will occlude later. Disable FG depth-write (`isDepthWriteEnabled=false` on the blend pass), keep depth-test.

## 4. Single biggest risk + simplest mitigation

**Risk:** the FG cut and the BG inpaint band are sized by independent formulas, so the cut can open a hole wider than the sharply-inpainted ribbon → black/stretched gap = a *new* halo.

**Mitigation (simplest):** derive both from one number. Set band width = `cut footprint + 1px margin`, i.e. inpaint exactly what the cut can reveal, computed from the *same* `P_max·Δd`. Concretely: after building the FG index buffer, rasterize the dropped-quad footprint into `B_mask` directly (union the cut quads), then `dilate(1)`, then feed *that* to LaMa and the far-depth fill. This makes "cut reveals only inpainted pixels" a structural guarantee instead of a parameter coincidence.

## 5. Concrete changes / safer variant

The primary path is feasible at 60fps, but it touches 7 files including a new depth attachment, two index buffers, a compute cut kernel, and three new `FloatImage` ops — high blast radius for v1. **Recommended: ship the documented Fallback first** (backward iterative warp in the fragment shader, zero geometry), gated behind the *narrow-band inpaint + soft-alpha* CPU fixes, which are where 80% of the visual win lives. The CPU changes (narrow band, far-depth fill, soft matte) fix the halo regardless of render path; the mesh only adds internal-subject parallax. Land CPU first, mesh second.

**VERDICT: blueprint sound with these 7 changes:**

1. **Tie band width to cut footprint** (rasterize dropped quads → dilate 1 → that *is* `B_mask`); removes the black-gap halo.
2. **Fix blend to non-premultiplied-correct:** `sourceRGBBlendFactor=.one` (mirror existing `mpiState`), or output straight alpha; current pseudo-code yields dark fringes.
3. **Disable FG depth-write** on the blend pass (test-only); feathered alpha must not occlude.
4. **β feathers ≤2–3px, not 3–8;** wider re-creates a faint halo over the only-partly-correct BG.
5. **Run band-grow + Sobel at 640, not full res;** keeps bake ~1s; the geodesic grow is the cost, not the filters.
6. **Widen `neutralizeColorCast` sampling ring** independent of the now-tiny hole, else color-match gets noisy.
7. **Add a debug clip-z visualization + assert `depthScale≤1`;** the inverted-disparity→z mapping is correct but untested and one sign error silently clips the subject. Ship the **fragment relief-march fallback first**, mesh second.

## Raw research notes by angle


---

### LDI / 3d-photo-inpainting

I have comprehensive material across all three papers and all five questions. Here is the technical note.

---

# LDI Lineage of Single-Image 3D Photography — Technical Note

Three papers define the "lift one RGB + mono-depth into a parallax-able scene" lineage. They diverge mainly on **representation** (explicit LDI graph vs. point cloud) and on **where inpainting happens** (on the geometry vs. on a flat render), but they converge on one core insight: *depth discontinuities must break geometric connectivity, and the resulting holes must be filled with both color AND depth.*

## 1. Representation: single RGB-D → geometry

**Shih et al. (CVPR 2020, vt-vl-lab/3d-photo-inpainting).** A **Layered Depth Image with explicit pixel connectivity**. Start from MiDaS mono-depth, build a *single-layer* LDI where every pixel is a node 4-connected to its neighbors (a graph on the image lattice, each node holding color + depth). Inpainting then *adds new layers locally* only behind depth edges — there is no fixed layer count or fixed spacing; layers are created on demand, one per processed depth edge, and a complex scene can accumulate several. Final output is a single fused **textured triangle mesh** (`.ply`).

**Kopf et al. (One Shot, SIGGRAPH Asia 2020, facebookresearch/one_shot_3d_photography).** Also an LDI: "a regular rectangular lattice where every position can hold zero, one, or more pixels," each LDI-pixel storing color + depth, with **4-connectivity** (each pixel has zero or one neighbor per cardinal direction). Key distinction from prior LDI work: *not limited to ≤2 layers* — disocclusion expansion runs ~50 iterations, growing overlapping layers wherever parallax demands. Depth comes from their **Tiefenrausch** mobile net.

**Niklaus (3D Ken Burns, SIGGRAPH Asia 2019, sniklaus/3d-ken-burns).** No layer graph — a **point cloud**. Pixels are unprojected to 3D via depth; disocclusion holes are filled by *appending new points* to the cloud. Camera path is known (Ken Burns scan/zoom), so inpainting is done once at the **extreme views** of the path and the recovered geometry is merged back into the cloud.

## 2. Depth-discontinuity handling (the key — avoiding rubber-sheet smear)

This is where all three earn their results. A naïve depth mesh triangulates the full lattice; triangles spanning a foreground/background cliff stretch into a "rubber sheet" smear. All three cut connectivity at depth edges instead.

**Shih:** sharpen depth, then detect **raw discontinuities by disparity threshold** between neighbors, discard short/spurious ones, and **link survivors into connected depth edges** (silhouettes around objects). For each edge, the LDI nodes straddling it are **disconnected** — connectivity is severed so no triangle/edge bridges the cliff. Only the **background side** of the cut is eligible for inpainting (the foreground occludes; the background is what's missing).

**Kopf:** 5×5 **weighted (bilateral) median filter**, disparity-Gaussian weighted (σ_disparity ≈ 0.2), sharpens depth onto pixels. Raw discontinuities via disparity threshold (τ_disp ≈ 0.05); connected-component cleanup merges blobs < ~20 px; survivors are **linked into connected depth edges**. The 4-connectivity is broken across these edges, so each layer is a separately-shaded surface. At the mesh stage, **charts are flood-filled respecting depth-folding constraints** — a chart is never allowed to fold over a discontinuity, so no triangle spans the cliff.

**Niklaus:** attacks the *cause* of fuzzy edges — a **semantic-aware depth net + segmentation-based depth adjustment + a boundary-refinement net** that snaps depth to crisp object boundaries. With a point cloud there are no shared triangles to stretch; a sharp depth edge simply yields a clean gap of missing points (later inpainted), which is why boundary sharpness is the crux for them.

**Takeaway:** detect depth edges by *disparity* (not color), link them into curves, and **break mesh/LDI connectivity exactly along them**. Everything downstream depends on this cut.

## 3. Disocclusion inpainting (color + depth)

All three inpaint **both color and depth** — depth is essential so re-projected fill geometry sits at the correct distance and survives further parallax.

**Shih — context-aware, iterative, edge-guided.** An agent processes depth edges one at a time. For an edge: (a) disconnect LDI pixels along it; (b) extract a **context region** on the known (background) side, bounded by other depth edges; (c) form a **synthesis region** on the unknown side by flood-fill, **dilated ~5 px** near the edge to absorb depth-estimation error. Three **U-Net sub-networks run in sequence: edge → color → depth.** The edge net first hallucinates how the silhouette *continues* into the hole; color and depth nets are then **conditioned on that inpainted edge** plus the context, so structure crosses the hole coherently instead of blurring. Inpainted pixels are **merged back as new LDI layers**, and the loop repeats. Band width is implicitly set by the synthesis-region flood-fill, not an explicit parallax bound.

**Kopf — inpaint on the LDI directly.** Their **Farbrausch** net inpaints occluded LDI pixels; they also give a recipe to **lift any 2D partial-convolution inpainting net onto an LDI** by aggregating each conv kernel via BFS over LDI neighbors (up/down/left/right traversal, zero-padding at silhouettes). Crucially, they **shape the continuation of the discontinuity into the disoccluded region with constraints** (perpendicular straight-line continuations at edge endpoints) to avoid T-junction artifacts — the same "extend the silhouette before filling" idea as Shih, expressed geometrically. The disocclusion expansion is **iterated (~50×)**, growing the fill outward layer by layer; width is bounded by the expansion budget rather than a closed-form parallax limit.

**Niklaus — context-aware on the render.** A single inpainting net takes an **incomplete novel-view render** where every pixel carries color + depth + context, and produces a **geometrically consistent color and depth completion**. Run at the path extremes (max parallax), the new color+depth is unprojected and **appended to the point cloud**, so subsequent in-between frames re-use it. Because it inpaints only the **extreme views**, the band it fills is naturally **bounded by the maximum parallax of the predetermined camera path** — the cleanest "bounded by expected parallax" answer of the three. All three are **context-aware (extend existing structure)** rather than free generative/diffusion fills.

## 4. Rendering for smooth, band-free parallax

The reason none of these show "layer banding": the discrete layers are **fused into one continuous textured surface before display**, with the only true breaks at real depth edges.

- **Shih / One Shot:** the multi-layer LDI is converted to a **single textured triangle mesh**. One Shot builds a **simplified mesh in 2D atlas space** (Douglas-Peucker polygon simplification), lifts vertices along their rays by depth, packs a **texture atlas** with **padding to stop cross-chart filter bleed**, and renders with a standard rasterizer. Connected regions are continuous (smooth parallax); cuts exist only at depth edges where inpainted backfill is now visible — so the eye sees parallax, not bands.
- **Niklaus:** render the **point cloud** from each camera pose along the path; the appended inpainted points fill disocclusions, giving temporally coherent video.

Net effect: **continuous geometry → continuous parallax**; the layering is an authoring-time device, invisible at render time.

## 5. On-device feasibility and what an A-series renderer should borrow

**One Shot is the on-device proof.** Tiefenrausch depth: ~3.5M params (int8), ~3.3 MiB model, **~230 ms on iPhone 11 Pro** at 288×384, ~196 MiB peak, ~6.4 GFLOPs (NAS + quantization). Whole pipeline runs **in a few seconds on a phone, offline**, and emits a compact textured mesh + atlas. Shih's pipeline is heavier (~2–3 min, GPU) — great quality, not real-time. Niklaus is offline/desktop.

### What to implement (concrete)
1. **Depth → disparity, then edge-detect on disparity.** Bilateral/weighted-median sharpen (5×5, σ_disp≈0.2), threshold (τ_disp≈0.05), drop components < ~20 px, **link into connected depth-edge curves**. This single step kills most smear.
2. **Cut connectivity at edges.** Build the render mesh from the lattice but **never emit a triangle whose vertices straddle a linked depth edge** (or whose vertex depth-delta exceeds τ_disp). This is the cheap, GPU-friendly anti-rubber-sheet trick — do this even if you skip ML inpainting.
3. **Backfill behind edges.** For real-time, precompute fill **offline once** (Shih-quality edge→color→depth, dilate synthesis ~5 px) and bake it into a **second mesh layer + texture atlas** behind each silhouette. At runtime the GPU just rasterizes both layers. If fully on-device, port a partial-conv inpainter to int8 (One Shot's BFS-on-LDI trick) and **bound the fill band by your max camera offset** (Niklaus' path-extreme idea) to cap work.
4. **Ship a single simplified textured mesh + padded atlas**, not per-pixel layers — Douglas-Peucker simplification + atlas padding gives smooth parallax, small memory, and trivial Metal rasterization. Drive parallax from device IMU/gaze for the live "wiggle."
5. **Budget:** a Tiefenrausch-class depth net (~3 MiB int8, sub-250 ms) + baked backfill mesh is squarely within A-series real-time; reserve the expensive context-aware inpaint for an offline/first-load bake, render-time stays a plain two-layer mesh draw.

## Sources
- [Shih et al. CVPR 2020 — abstract](https://arxiv.org/abs/2004.04727) · [project page](https://shihmengli.github.io/3D-Photo-Inpainting/) · [code](https://github.com/vt-vl-lab/3d-photo-inpainting) · [explainer](https://www.casualganpapers.com/single_view_layered_depth_3d_inpainting/3D-Inpainting-explained.html)
- [Kopf et al. One Shot 3D Photography — abstract](https://arxiv.org/abs/2008.12298) · [HTML full text (ar5iv)](https://ar5iv.labs.arxiv.org/html/2008.12298) · [code](https://github.com/facebookresearch/one_shot_3d_photography)
- [Niklaus 3D Ken Burns — abstract](https://arxiv.org/abs/1909.05483) · [project page](https://sniklaus.com/kenburns)

---

### SLIDE / soft layering

I now have all the technical detail I need: SLIDE's exact equations, the matting integration, the disocclusion map, the over-composite, and the rendering. I have enough on 3D Moments and Worldsheet from the searches. Let me write the technical note.

---

# Soft Layering for Artifact-Free Single-Image 3D Photos — A Technical Note

## The problem soft layering solves

A single-image 3D photo is built by lifting one RGB image into a depth-parameterized geometry and re-rendering it from a slightly moved camera. The classic failure modes both occur at **depth discontinuities** (object silhouettes):

- **Hard contour rings / "cardboard cutout" edges** — if you assign each pixel to exactly one of N discrete depth planes (or one mesh layer) by *thresholding* depth, the silhouette becomes a binary boundary. Under parallax it tears open as a crisp, opaque edge — a ring of foreground color floating against background, plus visible quantization steps (banding) where smoothly-varying depth was snapped to plane indices.
- **Rubber-sheet smear** — if instead you keep one continuous mesh and just stretch it, the foreground and background stay welded across the discontinuity. The triangles that span the depth jump get stretched into long, skewed "rubber sheets" that smear foreground texture across the disoccluded region.

These two artifacts are a dilemma: cutting (hard layers) gives rings; not cutting (single sheet) gives smear. **Soft layering** escapes the dilemma by replacing the binary silhouette decision with a *continuous per-pixel alpha*, and by giving the renderer a real, *inpainted* background to reveal through the now-semi-transparent edge.

## 1. What "soft layering" is (SLIDE, Jampani et al. ICCV 2021)

SLIDE uses exactly **two layers**: a foreground (FG) layer textured with the original RGB image `I` plus a **soft visibility/alpha map `A`**, and a background (BG) layer textured with an *inpainted* RGB `Ĩ` and inpainted disparity `D̃`. Both layers are turned into triangle meshes (back-project disparity to a 3D point per pixel; connect 4-neighbors into triangles), rendered to the target view, and composited.

The crucial idea is that `A` is **soft**, not binary. Visibility falls off continuously near depth edges so the foreground silhouette is *feathered*, partially transparent. This single choice kills both artifacts at once:

- **No hard rings/banding** — the edge is a smooth alpha ramp, not a step. There are no discrete plane indices to quantize, so there is no banding. The silhouette dissolves gradually instead of presenting a crisp opaque contour.
- **No smear** — because the FG mesh becomes transparent (`A→0`) exactly at the discontinuity, the renderer doesn't drag opaque foreground texture across the gap. Instead the transparency *reveals the inpainted background layer* sitting behind it. The stretch-region of the FG mesh contributes ~zero, so there is nothing to smear; what shows through is plausible, real-looking BG content.

So soft layering is "hard layering with the binary edge replaced by a continuous matte + a properly inpainted thing to see through it."

## 2. Computing the soft alpha and the depth-aware background

**Soft visibility from depth (Eq. 1):**
```
A = exp(−β · ||∇D||²)
```
`∇D` is the Sobel gradient of the disparity map; `β` controls falloff. Visibility is **inversely proportional to disparity-gradient magnitude**: flat regions stay fully opaque (`A≈1`), and at steep depth jumps `A→0`. This is a cheap, closed-form matte — no learned network, no bilateral/guided filter needed for the base case.

**Adding a learned alpha matte for thin structures.** Depth-gradient visibility alone cannot capture hair-thin structures (depth there is unreliable/blurred). SLIDE therefore *folds a segmentation-based soft alpha matte `M` into visibility*:
```
A' = A · (1 − (M̄ − M)(1 − Ŝ))
```
where `M̄` is the dilated matte and `Ŝ` the disocclusion map. Because visibility is already a *soft* quantity, plugging in a soft subject matte is trivial — it just multiplies in. This is the on-device-friendly hook: any external matte (a portrait subject matte) drops straight into the same `A`.

**Soft disocclusion map (Eq. 3):** a `tanh` of how much *more distant* a pixel is than its inpainting source, used to mark which BG pixels must be hallucinated.

**Depth-aware inpainting.** The BG layer (`Ĩ`, `D̃`) is filled by a learned inpainter, but trained specially: rather than only random free-form strokes, SLIDE trains the network on **occlusion-shaped masks that hug object silhouettes**, so the network learns to *borrow from larger-depth (farther) regions* and not bleed foreground color into the hole. This is what makes the revealed content behind the feathered edge look like real background rather than smeared foreground.

## 3. Why 2 soft layers beat N hard planes — the math of the over-composite

The final render is a standard **alpha over-composite (Eq. 4):**
```
I_T* = A_T · I_T + (1 − A_T) · Ĩ_T
```
where `A_T`, `I_T`, `Ĩ_T` are the FG visibility, FG render and BG render *warped to the target view T*.

Compare the two regimes:

- **N hard planes (MPI/LDI-style with binary assignment).** Each pixel lands on one of N planes. The composited color is `Σ_i (Π_{j<i}(1−α_j)) α_i c_i` with `α_i ∈ {0,1}`. With binary α and finite N, depth is a *staircase*: smoothly varying disparity gets snapped to plane indices ⇒ **banding** at every plane boundary, and the silhouette is an opaque step ⇒ **ring**. Increasing N reduces band width but multiplies seams, memory, and crack-prone layer boundaries.

- **2 soft layers.** `A_T ∈ [0,1]` is *continuous*. The over-composite `A_T·I_T + (1−A_T)·Ĩ_T` is a smooth convex blend: as the camera moves, `A_T` ramps from 1 to 0 across a few pixels, fading FG into the inpainted BG with **no discrete index to quantize** ⇒ no banding, no ring. Two well-separated, correctly-inpainted layers carry essentially all the occlusion information a moderate parallax needs; the continuous matte does the anti-aliasing that N planes tried (and failed) to approximate by brute force. Fewer layers also means fewer mesh seams that can crack.

In short: banding is a *quantization* artifact of discrete α and discrete depth; soft layering removes the quantization, not just refines it.

## 4. Keeping parallax continuous

SLIDE back-projects disparity to one 3D point per pixel and connects 2D-neighbors into a **triangle mesh**, rendered with a differentiable renderer. Continuity comes from (a) the mesh being a continuous surface (no plane-index jumps), and (b) the soft `A` controlling how stretched FG triangles fade out rather than smear. **3D Moments (Wang et al., CVPR 2022)** generalizes this to *feature-based* LDIs: it agglomerative-clusters RGBD into a few layers, inpaints color+depth+features per layer, then renders by **differentiable point/feature splatting** with depth-weighted soft blending (closer splats weighted higher, normalized) plus a small refinement CNN — soft accumulation again avoids cracks, and adding scene flow lets it interpolate motion too. **Worldsheet (Hu et al., ICCV 2021)** is the minimalist endpoint: shrink-wrap a single deforming mesh "sheet" onto the image via a differentiable texture sampler; it stays continuous by construction (one sheet, no layering) but needs stacked sheets to handle real occlusion — illustrating why ≥2 layers are needed once disocclusion matters.

## 5. What to implement (on-device 2-layer renderer with per-pixel depth + subject matte + inpainter)

1. **Build a continuous FG visibility map `A`, not a binary mask.** Start from `A = exp(−β·||∇D||²)` on the Sobel disparity gradient (one shader pass). Tune `β` so opacity ramps over ~3–8 px at strong edges.
2. **Fold the subject matte in, don't threshold it.** Combine your soft subject matte multiplicatively (`A' = A·(1−(dilate(M)−M)(1−S))`) so hair/fuzzy edges get partial transparency. Never binarize the matte — binarization is what creates the ring.
3. **Render two meshes, not N planes.** FG mesh from `D` textured with `(I, A')`; BG mesh from inpainted disparity `D̃` textured with `Ĩ`. Back-project depth → 3D point per pixel → connect 4-neighbors into triangles.
4. **Composite with the over operator in the target view:** `out = A_T·I_T + (1−A_T)·Ĩ_T`, where `A_T` is the *warped* visibility. Premultiply alpha to avoid dark/halo fringes; resample `A` with the same warp as color.
5. **Make the inpainter depth-aware.** Only inpaint the *disoccluded* region (use a `tanh`-style disocclusion map to mask it), and bias/train it to copy from *farther* (higher-depth) neighbors so it never paints foreground color into the hole. A depth-inpaint pass (`D̃`) is as important as the color pass — the BG mesh geometry must sit *behind* the FG.
6. **Suppress stretched FG triangles.** Drop or fade triangles whose disparity span exceeds a threshold (or rely on `A'→0` there) so the FG layer contributes nothing across the gap — this is what prevents smear; the inpainted BG shows through instead.
7. **Keep it to 2 layers + soft alpha for the parallax budget** of a photo viewer; reserve feature-splatting/extra layers (3D-Moments style) only if you need wider baselines or motion interpolation.

Sources: [SLIDE arXiv](https://arxiv.org/abs/2109.01068) · [SLIDE ar5iv HTML](https://ar5iv.labs.arxiv.org/html/2109.01068) · [SLIDE ICCV PDF](https://openaccess.thecvf.com/content/ICCV2021/papers/Jampani_SLIDE_Single_Image_3D_Photography_With_Soft_Layering_and_Depth-Aware_ICCV_2021_paper.pdf) · [SLIDE project page](https://varunjampani.github.io/slide/) · [3D Moments arXiv](https://arxiv.org/abs/2205.06255) · [3D Moments project](https://3d-moments.github.io/) · [3D Moments code](https://github.com/google-research/3d-moments) · [Worldsheet](https://worldsheet.github.io/) · [3D Photo Inpainting (hard-LDI baseline)](https://shihmengli.github.io/3D-Photo-Inpainting/)

---

### MPI lineage

I have all the technical detail needed. Here is the research synthesis.

---

# MPI Single-Image View Synthesis: Why Few Planes Band, and What This Means On-Device

## 1. Plane count and spacing — and why N≤8 bands

All four reference systems use **dense plane stacks** and **disparity-linear (inverse-depth) spacing**, not depth-linear:

- **Zhou et al. (Stereo Magnification, SIGGRAPH 2018)** — the original MPI — uses **32 fronto-parallel RGBA planes** at fixed depths, spaced uniformly in disparity (1/z) within [z_near, z_far].
- **Tucker & Snavely (CVPR 2020)** — single-view — predicts **32-layer MPIs**, planes "equally spaced in disparity."
- **MINE (Niantic, ICCV 2021)** uses **N=32 or 64** planes, sampled via stratified sampling in disparity: dᵢ ~ U[d_n + (i−1)/N·(d_f−d_n), d_n + i/N·(d_f−d_n)].
- **AdaMPI (SIGGRAPH 2022)** ships **32- and 64-plane** models, evaluated at 8/16/32/64; quality strictly improves with N (best at 64).

**Why disparity, not depth:** A camera's parallax shift for a point at depth z is proportional to **1/z** (disparity). Spacing planes uniformly in disparity puts the planes where parallax actually changes — many planes packed in the foreground (where a small depth change = large pixel motion) and few in the far background (where everything moves together). Depth-linear spacing wastes planes far away and starves the foreground, which is exactly where banding is most visible.

**Why N≤8 produces onion-ring banding:** With few planes, the continuous depth of a smoothly-sloped surface (a floor, a wall receding in z, a face) gets **quantized onto a handful of discrete fronto-parallel sheets**. When you translate the camera, each plane shifts by a *constant* parallax (its own disparity × baseline), but the true surface should shift by a *smoothly varying* amount. The result: the surface visibly snaps between plane depths, and the alpha transitions between adjacent planes trace out concentric arcs — the "onion ring"/staircase artifact. AdaMPI quantifies this: the average plane-depth correction its Plane Adjustment Network must apply is 0.086 (normalized disparity) at 8 planes but only 0.019 at 64 — i.e. at 8 planes each plane is badly mis-placed relative to real geometry, so banding is unavoidable without per-scene adaptation.

**How dense disparity sampling + alpha removes it:** With 32–64 disparity-spaced planes, adjacent planes are close enough in parallax that a sloped surface is split across **2–3 neighboring planes whose soft alphas blend**. As the camera moves, the surface's apparent depth interpolates smoothly between plane depths because energy is shared (via alpha) across consecutive planes. The quantization step becomes smaller than a pixel of parallax, so banding falls below the visible threshold. This is the core fix: **density + soft alpha = smooth depth interpolation**.

## 2. Learned soft alpha vs. hard boxcar membership

This is the crux of your problem. Your hard "boxcar membership" assigns each pixel to **exactly one** plane (α∈{0,1}). That is fundamentally what causes banding even before plane count: a surface is a step function over planes, so parallax is piecewise-constant.

Every reference system instead **learns continuous, per-pixel, per-plane soft alphas** (α ∈ [0,1]):
- Zhou/Tucker: the network *directly outputs* a soft alpha map per plane.
- MINE and AdaMPI go through a NeRF-style **volume density σ**, converted to alpha by **αᵢ = 1 − exp(−σᵢ·δᵢ)** (δᵢ = inter-plane distance). AdaMPI notes this density formulation yields sharper results than predicting alpha directly.

A real edge or sloped surface lands as a **soft ramp of alpha spread across several adjacent planes**. When the camera translates, the perceived surface position is the alpha-weighted average of those planes' parallax shifts — which moves *continuously*, not in steps. Soft alpha is also what lets MPI antialias depth discontinuities and render thin/fuzzy structures (hair, foliage) that a hard one-plane-per-pixel assignment shatters. **Replacing your boxcar with soft alpha is the single highest-leverage change**, more important than raw plane count.

## 3. Homography + over-composite math, and disocclusion

**Rendering** = warp every RGBA plane into the target view, then composite back-to-front.

*Warp:* Each fronto-parallel plane at depth zᵢ is a 3D plane; the mapping from source to target pixels is a planar homography:
Hᵢ = K_t (R − t·nᵀ/zᵢ) K_s⁻¹
where n=(0,0,1) is the plane normal, (R,t) the relative pose, K the intrinsics. In practice you do **inverse warping**: for each target pixel, apply Hᵢ⁻¹ and bilinearly sample the source plane.

*Over-composite (back-to-front "over" operator):* with transmittance Tᵢ = ∏_{j<i}(1−αⱼ),
Î = Σᵢ Tᵢ · αᵢ · cᵢ,  equivalently the recursive C = c_front·α_front + C_behind·(1−α_front).
MINE's volumetric form: Î = Σᵢ Tᵢ·(1−exp(−σᵢδᵢ))·cᵢ, Tᵢ = exp(−Σ_{j<i} σⱼδⱼ). Both warp and composite are differentiable, which is what makes the whole thing trainable end-to-end from a view-synthesis loss.

**Disocclusion behavior — it REVEALS, and the reveal is pre-inpainted at train time, not at render time.** MPI does *not* run an inpainter when you move the camera. Instead, the network is trained to **hallucinate plausible background content into the background planes behind foreground edges**, so that when parallax disoccludes a region, a *lower (farther) plane already contains color/alpha there* and is simply revealed by compositing. Tucker & Snavely state the network "learns to fill in content behind the edges of foreground objects in background layers" (aided by an edge-aware smoothness loss). AdaMPI makes this explicit with a **Context Mask** that lets a plane's color prediction use the "union of pixels on and behind" it (inpainting into occluded regions), trained with the warp-back strategy and an EdgeConnect inpainter for supervision. MINE "fills in occluded contents" by predicting RGB+σ at all depths. **Net: MPI bakes inpainting into the RGBA stack at inference time = zero; render = pure warp+composite.** This is a major advantage over a 2-layer LDI, which must inpaint the second layer and can still show holes at large parallax.

## 4. Real-time / on-device cost of 32–64 planes

The headline cost: an MPI is **N × (H×W×4) of RGBA texture**, and rendering is **N homography-warped, alpha-blended quads** per frame. The good news — repeatedly stressed in the literature — is that **MPI rendering is trivially GPU-friendly**: it is exactly N textured, alpha-blended billboards composited back-to-front, which is the bread-and-butter of any mobile GPU. Unlike NeRF, "an MPI can be efficiently rendered on graphics hardware."

Costs and the standard reduction tricks:
- **Generation vs. render are separate.** The CNN runs *once* to produce the stack; rendering at 60fps is just the N-quad composite. AdaMPI generates a 64-plane MPI at 256×384 in 0.072s on a V100 (one-time). On mobile, generation is the bottleneck (run once, async), not per-frame rendering.
- **Memory is the real mobile constraint.** 32 planes at 1024² RGBA16F ≈ 256 MB; 64 ≈ 512 MB. That's the pressure point on a phone, plus the per-frame fill-rate of compositing 32–64 full-screen layers.
- **Reduce plane count with adaptive placement.** AdaMPI's Plane Adjustment Network shows scene-adaptive plane depths let *fewer* planes match the quality of more uniform planes — the lever for dropping from 64 toward ~16–24 without banding.
- **Tiled MPI (2023):** depth complexity is locally low, so split the image into tiles each with only a few planes — "comparable results with lower computational overhead." This kills the redundancy of full-screen dense planes.
- **Convert MPI → textured mesh / RGBA+depth layers.** Broxton et al. (Immersive Light Field Video) collapse a large plane/shell stack into "a small, fixed number of RGBA+depth layers" rendered as **alpha-textured meshes**, then atlas+video-compress them. This is the production path for real-time/mobile: an MPI is an *intermediate*; you ship a handful of alpha-meshes. Fill-rate drops from N full-screen layers to a few meshes covering only their occupied pixels.

## 5. Concrete verdict for your on-device 60fps, no-3rd-party-deps demo

**Use a hybrid: generate a moderate MPI (or per-plane soft-alpha layers) once, then bake it down to a small set (≈4–8) of soft-alpha RGBA+depth layers / textured meshes for real-time rendering.** Do *not* render 32–64 raw planes per frame on a phone, and do *not* keep your hard 2-layer boxcar.

Reasoning:
- **Your banding is not primarily a plane-count problem — it's the hard boxcar.** Switching to **soft per-pixel alpha** (even with your current ~2 layers) is the first fix and removes the worst stair-stepping and edge shattering. This alone is mandatory.
- **Dense MPI (32–64 planes) at render time is the wrong on-device choice** for 60fps: 256–512 MB texture + compositing 32–64 full-screen alpha layers is a memory and fill-rate hazard on mobile, for quality most users won't perceive at small parallax.
- **But MPI is the right *generation/intermediate* representation.** It gives you (a) automatic, render-time-free disocclusion inpainting baked into background layers — which a naive 2-layer LDI/mesh cannot match, and (b) soft antialiased edges. Generate it offline/async once per photo.
- **Then collapse to ~4–8 alpha-RGBA+depth layers rendered as meshes** (the Broxton/Tiled-MPI strategy). With disparity-spaced placement and soft alpha, 4–8 layers is enough to avoid banding for the modest parallax of a photo-wiggle demo, fits comfortably in mobile memory, and renders as a handful of alpha-blended textured quads — trivially 60fps with zero third-party deps (just your GPU API).

Bottom line: **soft alpha + disparity spacing are non-negotiable; dense 32–64 planes are an offline detail you bake away.** A 2-layer LDI is too few layers and leaves you doing your own inpainting; raw dense MPI is too heavy to render live. The sweet spot is an MPI-derived, soft-alpha, ~4–8-layer mesh/RGBA+depth stack.

## Sources
- [Tucker & Snavely, Single-View View Synthesis with MPI (CVPR 2020)](https://openaccess.thecvf.com/content_CVPR_2020/papers/Tucker_Single-View_View_Synthesis_With_Multiplane_Images_CVPR_2020_paper.pdf) · [project](https://single-view-mpi.github.io/) · [code](https://github.com/google-research/google-research/tree/master/single_view_mpi)
- [MINE, Towards Continuous Depth MPI with NeRF (ICCV 2021)](https://arxiv.org/abs/2103.14910) · [ar5iv](https://ar5iv.labs.arxiv.org/html/2103.14910) · [code](https://github.com/vincentfung13/MINE)
- [AdaMPI, Single-View View Synthesis in the Wild (SIGGRAPH 2022)](https://ar5iv.labs.arxiv.org/html/2205.11733) · [code/docs](https://github.com/yxuhan/AdaMPI)
- [Zhou et al., Stereo Magnification (SIGGRAPH 2018)](https://tinghuiz.github.io/papers/siggraph18_mpi_lowres.pdf) · [code](https://github.com/google/stereo-magnification)
- [Tiled Multiplane Images for Practical 3D Photography (2023)](https://arxiv.org/abs/2309.14291)
- [Broxton et al., Immersive Light Field Video with a Layered Mesh Representation (SIGGRAPH 2020)](https://history.siggraph.org/experience/immersive-light-field-video-with-a-layered-mesh-representation-by-broxton-flynn-overbeck-erickson-hedman-et-al/)
- [One Shot 3D Photography (LDI baseline, 2020)](https://ar5iv.labs.arxiv.org/html/2008.12298)

---

### Apple + productized

I have all the technical depth I need across the seven products plus the SLIDE reference that ties the methods together. Here is the synthesis.

---

# How shipping products turn one 2D photo into a 3D/parallax photo

The entire industry converges on one recipe: **monocular depth estimation → a depth-driven geometry (mesh or layered image) → fill the holes revealed by camera motion (inpaint, or hide them) → a constrained camera path.** Products differ mainly in (a) which geometry they use, (b) how they treat depth *edges*, and (c) whether they actually inpaint disocclusions or just avoid revealing them. Below, each product, then the realistic Apple-quality bar.

## 1. Per-product representation, edge quality, and disocclusion fill

**Google Cinematic Photos (Pixel / Google Photos).** Representation: a **single textured mesh** — the RGB image extruded onto its depth map. It is a 3D-ify of an existing photo and is meant to be viewed only along a tightly constrained path. Edge quality: their CNN depth (encoder-decoder, scale-and-shift-invariant loss) is median-filtered, and they run a DeepLab person segmentation to fix background pixels wrongly glued to a person. Disocclusion: **they do not inpaint at all.** A naive mesh stretches like rubber where the camera reveals what was behind the subject ("the input texture is stretched"). Their trick is to *steer the camera around the problem*: a loss function quantifies how much stretch is visible, splits the frame into head/body/background via a pose net, and optimizes the per-photo camera trajectory to push any stretch artifacts into the background, never near the subject's face. So the "background behind a moved subject" is never really filled — the motion is limited so the hole barely opens.

**Meta / Facebook 3D Photos — "One Shot 3D Photography" (on-device).** Representation: a true **Layered Depth Image (LDI)** converted to a small textured mesh (~300–500 KB glTF). This is the gold-standard mobile pipeline. Edges: depth is sharpened with a 5×5 weighted-median filter (Gaussian-weighted by disparity, σ=0.2) and connected-component cleanup drops isolated blobs under 20 px. Disocclusion: it genuinely **synthesizes new geometry and color behind the subject.** Occluded surfaces are hallucinated by growing depth discontinuities (grouped into curve-like features with constraints to avoid T-junction smear) over ~50 expansion iterations, producing *multiple* layers (not capped at two). The "Farbrausch" inpainting network then paints color directly on the LDI graph by walking LDI connectivity in BFS to apply normal conv kernels to irregular topology. So when the subject moves, there is real inpainted background behind it — the best edge/disocclusion quality of the consumer set.

**Apple iOS 16/17 Lock-Screen Depth Effect → iOS 26 "Spatial Scenes" → visionOS "Spatial Photos."** Three different bars:
- *Lock-Screen Depth Effect (iOS 16+):* essentially **two layers** — subject matte cut from background — letting the clock tuck behind the subject. No real parallax fill; it's compositing, not novel-view rendering.
- *Spatial Scenes (iOS 26):* generative-AI depth + element separation produces a **layered parallax** that responds to gyroscope/head motion. Foreground holds steady, background shifts. Because motion is gyro-limited and small, disocclusion holes stay tiny; Apple's generative model fills them well enough to feel solid.
- *visionOS Spatial Photos:* the goal is **stereo, not parallax** — ML infers a second eye viewpoint and packages **left+right images as a stereo HEIC**. There's no user-driven camera, so disocclusion is bounded by interpupillary distance (~6 cm) and is small and consistent; the network only has to fill that fixed, narrow gap. This is why it works on "almost anything" (screenshots, posters).

**Immersity AI / LeiaPix.** Representation: server-side **neural depth (their "Neural Depth Engine," trained on millions of 3D/lightfield images) → layered depth + animated camera path**, with optional lightfield output for Leia displays. Because it's cloud and animated along a designed path, it can afford heavier inpainting; visible quality is high but edges can still "swim" on thin structures. Background fill is depth-aware inpainting; the user controls camera path and previews before committing.

**Owl3D.** Representation: **monocular depth → per-eye pixel shift (DIBR, depth-image-based rendering)** for stereoscopic 3D TVs/VR, plus temporal depth smoothing for video. It's stereo-pair generation, not free-viewpoint; disocclusions are handled by horizontal pixel-shift + hole-filling, and the small baseline keeps holes manageable. Edge artifacts show on fine/transparent objects, typical of DIBR.

## 2. Google Cinematic Photos pipeline specifics

Their published flow is **depth (CNN, monocular cues, scale-and-shift-invariant loss, trained on a 5-camera rig + Pixel-4 portraits with MVS ground truth) → median-filter + DeepLab person segmentation to fix depth edges → extrude RGB onto depth = textured mesh → optimize a per-photo camera path → frame using a per-pixel saliency net so the mesh fills every frame.** The key insight for a renderer: **at depth edges they do NOT prevent stretching by inpainting; they prevent *seeing* it.** The camera-path loss uses padded head/body/background masks to bias optimization toward letting stretch happen only in background regions far from the subject. Disocclusion is "handled" by never opening a large hole — small, slow, subject-pivoted motion. This is the cheapest possible approach and is why Cinematic Photos ships at scale with no inpainting network.

## 3. Meta 3D Photos on-device, in detail

LDI is the representation, and everything is NAS-optimized + int8-quantized for phones. On an iPhone 11 Pro at 288×384: depth net (Tiefenrausch) 230 ms / 3.3 MiB int8; depth clean 63 ms; occluded-geometry synthesis 31 ms; color inpaint (Farbrausch) 540 ms / 0.37 M params; meshing+texture 234 ms — **~1.1 s end-to-end**, final asset 300–500 KB glTF. Edge handling = weighted-median depth sharpening + curve-constrained discontinuity growth so disocclusion geometry doesn't fan out into T-junction smears. This is the realistic ceiling for *true on-device inpainted* 3D photos.

## 4. The realistic "Apple-quality" bar, and the convergent method

A single-photo, on-device renderer can realistically hit the **Spatial-Scenes / Lock-Screen bar, not the full free-fly bar:**
- **Convincing parallax under small, bounded motion** (gyro tilt or a short auto-pan), where disocclusion holes are small. At that scale you don't strictly need a heavy inpainter — soft edges + slight background hole fill suffice.
- **Clean subject silhouettes** via a good matte (hair-level alpha), because the eye forgives background swim but punishes a jagged subject edge. Apple's quality comes mostly from segmentation + soft edges, not from heroic inpainting.
- **No visible rubber-sheet on the subject** — achieved by feathering/alpha at depth discontinuities (SLIDE's trick) rather than a hard mesh.

The research that explains *why* this is achievable cheaply is **SLIDE (ICCV 2021)**: instead of hard layers, make foreground visibility a *soft alpha* that drops at depth edges, `A = e^(−β‖∇D‖²)`, so background shows through edges instead of stretching; add a smooth soft-disocclusion mask to guide light background inpainting; keep it **two layers, one forward pass (~0.07 s at 672×1008)**. That is the sweet spot for a renderer.

---

### Method these products converge on
**Monocular depth → depth-edge-aware layering (soft alpha at discontinuities, with a subject matte) → fill or hide disocclusions (inpaint if you can afford it à la Meta; otherwise constrain the camera à la Google) → a bounded, subject-pivoted camera path.**

### Concrete takeaways for your on-device renderer
1. **Don't render a naive single mesh.** A hard extruded mesh rubber-sheets at every edge. Use **soft alpha at depth discontinuities** (SLIDE's `e^(−β‖∇D‖²)`) so edges feather instead of stretch — biggest quality-per-effort win.
2. **Invest in the subject matte, not the inpainter.** A hair-accurate foreground alpha (segmentation) buys most of the perceived "Apple quality." Background swim is forgiven; subject jaggies are not.
3. **Sharpen depth before geometry:** 5×5 weighted-median (Gaussian by disparity) + drop connected components < ~20 px. Cheap, removes flying pixels and edge halos.
4. **Bound the camera to bound disocclusion.** Like Google, pivot near the subject and keep amplitude small (gyro-driven or short auto-pan); optimize/limit motion so holes stay tiny — then you can skip a heavy inpaint network entirely and still look solid.
5. **Two layers + small hole fill beats N-layer LDI for a phone.** SLIDE shows two soft layers in one forward pass (~70 ms) rivals multi-layer LDI. Reserve full LDI + Farbrausch-style inpainting only if you need large free-fly motion (Meta's ~1.1 s budget).
6. **Pick your target tier explicitly:** stereo (fixed ~6 cm baseline, easiest — visionOS/Owl3D) vs. gyro-parallax (small motion — Spatial Scenes) vs. free-fly animation (needs real inpaint — Meta/Immersity). For an on-device demo, **gyro-parallax with soft-edge two-layer + matte** is the realistic Apple-quality target.

Sources:
- [Google Research: The Technology Behind Cinematic Photos](https://research.google/blog/the-technology-behind-cinematic-photos/)
- [Meta/Facebook: One Shot 3D Photography (arXiv 2008.12298)](https://ar5iv.labs.arxiv.org/html/2008.12298)
- [Synced: Facebook One-Shot On-Device 3D](https://syncedreview.com/2020/08/31/facebook-one-shot-on-device-model-efficiently-transforms-smartphone-pics-into-3d-images/)
- [SLIDE: Single Image 3D Photography with Soft Layering and Depth-aware Inpainting (arXiv 2109.01068)](https://ar5iv.labs.arxiv.org/html/2109.01068)
- [MacRumors: iOS 26 Spatial Scenes](https://www.macrumors.com/how-to/ios-3d-lock-screen-effect-spatial-scenes/)
- [Apple Developer: Writing Spatial Photos (stereo HEIC)](https://developer.apple.com/documentation/imageio/writing-spatial-photos)
- [Road to VR: Vision Pro 2D→3D photo conversion](https://www.roadtovr.com/apple-vision-pro-will-soon-let-you-convert-2d-photos-to-3d-share-them-live-via-shareplay/)
- [Immersity AI / LeiaPix Neural Depth Engine](https://aisharenet.com/en/immersity-ai/)
- [Owl3D: 2D to stereoscopic 3D with AI depth maps](https://www.owl3d.com/blog/2d-to-stereoscopic-3d-with-ai-depth-map-from-a-single-image)

---

### DIBR / mesh-warp GPU

I now have comprehensive material from authoritative sources. Let me synthesize the implementable Metal-focused answer.

---

# Real-time per-pixel parallax from RGB-D on an A-series GPU (Metal)

## Background: the four families

**DIBR / forward 3D warping.** Classic Depth-Image-Based Rendering lifts each source pixel into 3D using its depth, then re-projects ("forward warps") it into the novel view. It is computationally simple but scatters source pixels onto a target raster, so it produces **cracks** (sub-pixel gaps from magnification) and **holes/disocclusions** at object borders where background that was hidden becomes visible. Backward warping is higher quality but needs a target-view depth map you don't have a priori, hence the iterative approaches below.

**Textured depth-grid mesh.** Build a triangle grid over the image, displace vertices by depth, render with a normal rasterizer. The GPU interpolates ("gathers") for free, eliminating cracks. The catch: a triangle that straddles a depth cliff gets stretched into a "rubber sheet" connecting foreground to background. The fix, used in essentially every depth-mesh view-synthesis system, is to **cut** those triangles: *"depth discontinuities have to be handled by breaking all edges with large differences and removing those corresponding triangles."*

**Backward iterative warp (relief mapping / POM / steep parallax).** Per output pixel, march a ray through the disparity field to find the source texel that warps to this pixel. Relief mapping does a linear search + binary refinement; steep parallax mapping stops at the first layer crossing; parallax-occlusion mapping (POM, Tatarchuk/Brawley 2005) interpolates between the last two layers for a smooth result.

---

## 1. Forward mesh warp — building and cutting the grid

**Mesh.** Generate a grid with one vertex per pixel (or per K=2–4 px to cut vertex count 4–16×; on A-series, a full-res 1080p grid is ~2M verts and is fine, but K=2 halves bandwidth). Each vertex carries its `(u,v)` and a **disparity** `d` (you warp by disparity = parallax proportional to `baseline/depth`, not by raw metric depth — disparity is what moves linearly in screen space).

**Displacement.** Parallax is a pure 2D screen-space shear of the source: a vertex moves by `parallaxAmount * (d - pivotDisparity)` along the view-offset direction. `pivotDisparity` is the "screen plane" (often the median/focus disparity) so the focus subject stays put and near/far objects shear opposite ways.

**Cliff detection — the key step.** Pass disparity to the vertex shader as a per-vertex attribute, and detect cliffs **per triangle**. The robust place to do this is at mesh-build time on the CPU/compute pass: for each candidate triangle, compute `max(d) - min(d)` over its 3 vertices; if it exceeds a threshold `τ` (e.g. a few disparity units, or adaptively `τ = k * localDisparityStddev`), **drop the triangle from the index buffer** (don't emit its indices). Dropped triangles leave a hole exactly along the silhouette; the background layer drawn behind fills it. (You can also degenerate the triangle in the vertex stage by collapsing it, but index-buffer dropping is cleaner and saves fill.)

```metal
// Vertex stage: pure screen-space shear by disparity
struct VOut { float4 pos [[position]]; float2 uv; };

vertex VOut warpVS(uint vid [[vertex_id]],
                   const device float2* uvBuf   [[buffer(0)]],
                   const device float*  dispBuf [[buffer(1)]],
                   constant Uniforms& U          [[buffer(2)]]) {
    float2 uv = uvBuf[vid];
    float  d  = dispBuf[vid];
    float2 shear = U.parallax * (d - U.pivotDisparity) * U.viewDir; // viewDir = 2D offset dir
    float2 ndc = (uv + shear) * float2(2,-2) + float2(-1,1);
    VOut o; o.pos = float4(ndc, 0, 1); o.uv = uv; return o;
}
```

A compute kernel builds the index buffer, appending the two triangles of each 2×2 quad only if `max-min disparity <= τ`:

```metal
kernel void buildIndices(const device float* disp [[buffer(0)]],
                         device atomic_uint* count [[buffer(1)]],
                         device uint* idx          [[buffer(2)]],
                         constant GridParams& G    [[buffer(3)]],
                         uint2 gid [[thread_position_id_in_grid]]) {
    uint i00=gid.y*G.w+gid.x, i10=i00+1, i01=i00+G.w, i11=i01+1;
    float a=disp[i00],b=disp[i10],c=disp[i01],e=disp[i11];
    float spread = max(max(a,b),max(c,e)) - min(min(a,b),min(c,e));
    if (spread > G.tau) return;                      // CUT: skip cliff quad
    uint base = atomic_fetch_add_explicit(count, 6, memory_order_relaxed);
    idx[base+0]=i00; idx[base+1]=i10; idx[base+2]=i11;
    idx[base+3]=i00; idx[base+4]=i11; idx[base+5]=i01;
}
```

**Pros:** GPU-interpolated, no cracks, correct occlusion via the depth buffer (write `d` to depth so nearer fragments win). **Cons:** holes need an explicit background; sliver triangles near cliffs can still leak a 1-px halo of foreground color (mitigate by eroding the foreground 1 px or by alpha-feathering cut edges).

---

## 2. Backward iterative warp (fragment-only)

No mesh. For each output pixel `p`, you want the source pixel `s` such that `s + parallax*(disp(s)-pivot)*dir == p`. Because `disp` is unknown along the way, you **march**: start at `p`, step backward along `-dir`, and at each step compare the disparity the field *has* at the sampled location to the disparity *required* to land at `p`. This is exactly the relief-mapping height-field intersection, with disparity playing the role of height.

```metal
fragment float4 backwardWarpFS(VOut in [[stage_in]],
                               texture2d<float> color [[texture(0)]],
                               texture2d<float> disp  [[texture(1)]],
                               sampler s [[sampler(0)]],
                               constant Uniforms& U) {
    const int N = 24;                          // linear steps
    float2 dir   = U.viewDir;                   // epipolar/parallax direction
    float2 P     = U.parallax * dir;            // max search vector
    float2 dUV   = P / float(N);
    float2 uv    = in.uv;
    float  reqLayer = 0.0, layerStep = 1.0/float(N);
    float2 cur = in.uv;
    float  dCur = (disp.sample(s,cur).r - U.pivotDisparity);
    // march until required parallax for THIS pixel exceeds field's parallax
    for (int i=0; i<N && reqLayer < dCur; ++i) {
        cur -= dUV; reqLayer += layerStep;
        dCur = (disp.sample(s,cur).r - U.pivotDisparity);
    }
    // binary refine (relief mapping) — 5 steps
    float2 lo=cur, hi=cur+dUV;
    for (int i=0;i<5;++i){ float2 m=0.5*(lo+hi);
        float dm=(disp.sample(s,m).r-U.pivotDisparity);
        if (dm < /*req at m*/ reqLayer) hi=m; else lo=m; }
    return color.sample(s, 0.5*(lo+hi));
}
```

**Pros:** continuous parallax, *correct occlusion for free* (the march naturally stops at the nearest occluder, so the foreground silhouette is exact — no rubber-sheeting and no separate cut logic). One pass, no geometry. **Cons:** cost is per-pixel × steps; under-sampling causes **stair-step/swim** artifacts on smooth ramps and **silhouette aliasing**; the march also cannot invent disoccluded background — where the ray finds no valid hit you still need a fallback layer. Step count must scale with parallax magnitude and grazing angle.

---

## 3. Which for *small* (few-percent) parallax + 2-layer setup?

For small parallax with a **2-layer fg + inpainted bg** representation, the **forward depth-mesh warp is more robust and simpler**, and it is what production mobile 3D-photo systems converge on (Facebook *One Shot 3D Photography* lifts depth to an LDI, inpaints parallax regions, and **converts to a mesh** precisely because a cut mesh renders cheaply and correctly on low-end GPUs). Reasons:

- With only a few percent shift, disocclusion bands are **narrow** (a few px). A pre-inpainted background fully covers them, so the mesh's only job is cut + shear — trivial and artifact-free.
- The march in method 2 needs enough steps to resolve those same few pixels without swimming; you pay per-pixel cost for sub-pixel motion. The mesh gets exact silhouettes from rasterization at lower ALU cost.
- Cutting triangles is deterministic and stable across frames (no temporal swim), which matters for the continuous parallax-on-tilt use case.

Use method 2 only if you must avoid any CPU/compute mesh build, or want zero geometry buffers.

---

## 4. Concrete Metal sketch: 2-layer cut-mesh composite, no wide halo

Render **back-to-front**: first the inpainted background layer as a *full uncut grid* (it has no cliffs — it's the completed bg), then the **foreground cut mesh** on top with alpha. The narrow disocclusion band is revealed simply because the cut removes the cliff triangles, exposing the bg behind — and because the bg is pre-inpainted, **no halo and no stretched smear** appears in that band.

The one remaining halo source is the 1-px mixed-color edge texels on the foreground silhouette ("ghosting/halo artifacts are a mixture of colors at the edges projected into neighboring objects"). Kill it with an **edge alpha-feather driven by local disparity gradient**, so the cut edge fades over ~1 px instead of leaving a hard fringe — narrow band, no wide halo:

```metal
// Foreground pass (cut mesh). disp & a feathered alpha precomputed per vertex.
vertex FOut fgVS(uint vid [[vertex_id]],
                 const device float2* uv   [[buffer(0)]],
                 const device float*  disp [[buffer(1)]],
                 const device float*  edge [[buffer(2)]],   // 0..1: near-silhouette -> 0
                 constant Uniforms& U      [[buffer(3)]]) {
    float d = disp[vid];
    float2 shear = U.parallax*(d - U.pivotDisparity)*U.viewDir;
    FOut o;
    o.pos   = float4((uv[vid]+shear)*float2(2,-2)+float2(-1,1), d*U.depthScale, 1);
    o.uv    = uv[vid];
    o.alpha = edge[vid];               // feather toward silhouette
    return o;
}

fragment float4 fgFS(FOut in [[stage_in]],
                     texture2d<float> fgColor [[texture(0)]],
                     sampler s [[sampler(0)]]) {
    float4 c = fgColor.sample(s, in.uv);
    c.a *= in.alpha;                   // 1px feathered cut edge
    return c;                          // blended over already-drawn bg
}
```

Pipeline: bg pass writes color (depth optional) → fg pass with `blending = srcAlpha/1-srcAlpha`, depth-test `less` so fg occludes bg where present. The `edge[]` attribute is computed once: `edge = smoothstep(0, τ, τ - |∇disp|)` at each vertex, so vertices adjacent to a cut get α→0. Result: foreground shears with true parallax, cliffs are cut (no rubber sheet), the narrow disoccluded strip shows pre-inpainted background (no smear), and the silhouette is feathered over a single pixel (no wide halo).

For the few-percent case you can even **prebuild the cut index buffer once** and only update the vertex shear uniforms per frame, making the per-frame cost a single shear + two textured draws — ideal for a 60–120 fps tilt-parallax loop on an A-series GPU.

---

## Sources

- [DIBR / 3D warping survey — Spatio-temporal consistent DIBR using LDI and inpainting (EURASIP JIVP)](https://jivp-eurasipjournals.springeropen.com/articles/10.1186/s13640-016-0109-6)
- [Forward vs backward warping, disocclusion handling — FR-DIBR (ResearchGate)](https://www.researchgate.net/publication/293811832_A_Forward_and_Reverse_Wrapping_Depth_Image-Based_Rendering_FR-DIBR_Method_for_Arbitrary_View_Generation)
- [DMesh: Fast Depth-Image Meshing and Warping (UZH) — grid meshing + cutting edges at discontinuities](https://www.ifi.uzh.ch/dam/jcr:ffffffff-82b7-d340-0000-000049cad1d5/DMesh.pdf)
- [Relief mapping — linear search + binary refinement (Grokipedia)](https://grokipedia.com/page/relief_mapping_computer_graphics)
- [LearnOpenGL — Parallax / Steep Parallax / Parallax-Occlusion Mapping (concrete shader loop)](https://learnopengl.com/Advanced-Lighting/Parallax-Mapping)
- [Parallax occlusion mapping (Wikipedia / Tatarchuk-Brawley 2005)](https://en.wikipedia.org/wiki/Parallax_occlusion_mapping)
- [One Shot 3D Photography — LDI lift, inpaint parallax regions, convert to mesh for mobile (arXiv 2008.12298)](https://ar5iv.labs.arxiv.org/html/2008.12298)
- [3D Photography using Context-aware Layered Depth Inpainting (arXiv 2004.04727)](https://arxiv.org/pdf/2004.04727)

---

### narrow-band disocclusion

I now have all the material needed. Here is the research synthesis.

---

# Narrow Disocclusion Bands: Compute, Inpaint Sharp, Keep Edges Crisp

## 1. Geometry: why the band is THIN, and how to localize it per-edge

When you re-render from a slightly translated camera, a pixel at disparity `d` shifts by `parallax * d` (disparity ∝ 1/depth). At a depth edge, the foreground pixel and the background pixel that were adjacent get pulled apart by **different** amounts. The gap that opens up — the disocclusion — has width:

```
band_width ≈ parallax_magnitude * (disparity_front − disparity_back)
```

This is exactly the DIBR result: holes appear only at sharp depth discontinuities, and their size scales with the baseline (parallax) times the depth jump ([EURASIP/Springer](https://jivp-eurasipjournals.springeropen.com/articles/10.1186/s13640-016-0109-6)). For a few-percent parallax this is a handful of pixels — so dilating the entire subject silhouette by a fixed fat radius is wrong: it creates a wide halo, throws away good foreground pixels, and forces the inpainter to hallucinate texture it didn't need to.

**Deriving the per-edge mask from the disparity gradient** (this is the core trick):

1. **Find depth edges by thresholding the disparity difference between neighboring pixels** ([3D-Photo-Inpainting](https://leeyngdo.github.io/blog/computer-vision/2023-12-31-3d-photography/)). Compute `∇D` (Sobel). An edge pixel is one where `|∇D| > τ`. Run connected-component labeling and drop segments shorter than ~10 px to kill noise.
2. **Pick the revealed (far) side only.** A disocclusion is revealed on the side the camera moves *toward* the background — i.e., the *down-gradient* side of the edge. The sign of `∇D` dotted with the parallax direction tells you which side. Mask pixels only there; the near (foreground) side stays untouched. This is what makes the band one-sided instead of a symmetric halo.
3. **Width-modulate the mask.** Set the local band thickness to `ceil(parallax * (d_front − d_back))` per edge pixel, clamped to a small range (e.g., 2–8 px). SLIDE encodes the same idea continuously: visibility falls off as a function of disparity-gradient magnitude, `A = exp(−β·||∇D||²)` ([SLIDE](https://ar5iv.labs.arxiv.org/html/2109.01068)), so steeper edges = wider transparent band.

This yields a thin, edge-localized, one-sided ribbon — not a dilated blob.

## 2. DEPTH inpainting: the band must get the FAR depth, never interpolated

The revealed band belongs to the **background**. Its depth must be the far disparity `d_back`, flat into the edge — NOT a ramp from front to back. (Some naive DIBR methods linearly interpolate front→back depth across the band, which produces a sloped "ramp" surface that looks like a rubber sheet; avoid that.)

The principled approach is **background-constrained / fill-from-the-far-side**:

- In the layered-depth-image (LDI) view, the synthesis region for an edge is **"needed for background only, relative to the layer in front,"** and is grown by flood-fill from the *context* (known background) region ([Casual GAN Papers / CVPR'20](https://shihmengli.github.io/3D-Photo-Inpainting/)). The context region is the connected far-side neighborhood; the synthesis region starts at the silhouette, **"takes one step in the direction where pixels are disconnected,"** and expands without crossing back over the silhouette.
- The inpainter is told to **"borrow from the regions with larger depth values"** — i.e., copy/extend the background depth statistics, not the foreground's ([SLIDE](https://ar5iv.labs.arxiv.org/html/2109.01068)). 3D-Photo-Inpainting runs a small **edge→depth→color** network cascade so the inpainted depth respects the predicted background structure.

Practical version for you: seed the band's disparity from the adjacent known background pixels (the down-gradient neighbors) and diffuse *only inward from the far side* (a one-sided/anisotropic flood-fill or fast-marching constrained to `≤ d_back + ε`). This guarantees a flat far-depth fill with a clean step at the foreground edge.

## 3. Keeping FG edges crisp: matting + soft-alpha compositing

A hard binary silhouette plus warping produces **ghosting / color fringing** — "a mixture of colors at the edges projected into neighboring objects" ([search summary](https://jivp-eurasipjournals.springeropen.com/articles/10.1186/s13640-016-0109-6)). The fix is to composite with a **soft alpha matte**, not a hard mask.

- **Build a trimap from your binary matte** by erosion/dilation: eroded interior = 255 (sure FG), dilated boundary ring = 127 (unknown), rest = 0 ([LearnOpenCV/FBA](https://learnopencv.com/image-matting-with-state-of-the-art-method-f-b-alpha-matting/)). The unknown ring should be only a few pixels — same scale as your band.
- **Refine alpha** with either a **guided filter** ("guided feathering": a guided filter applied to the binary mask under the RGB image as guidance gives a per-pixel alpha; it's the default edge-refinement in modern matting and recovers hair-fine detail), **closed-form / matting-Laplacian**, or a deep matter like **FBA**, which outputs **α, F, and B simultaneously** and runs a fusion module that enforces `C = αF + (1−α)B` to **decontaminate** the foreground color and kill halos ([FBA paper](https://arxiv.org/pdf/2003.07711)). Note guided filter can itself introduce mild halos where the window straddles a high-contrast edge ([WGIF discussion](https://scispace.com/pdf/filter-based-alpha-matting-for-depth-image-based-rendering-38kzgj4r64.pdf)); keep its radius small.
- **Composite with the decontaminated F** (premultiplied), so the fringe pixels carry true foreground color at partial alpha:
  `I = A·F + (1−A)·I_background`
  SLIDE's compositing is exactly `I* = A·I_fg + (1−A)·I_bg`, and it folds the matte into visibility as `A' = A·(1 − (M̄ − M)(1 − Ŝ))`, combining the depth-edge visibility with the alpha matte so hair survives and edges don't halo ([SLIDE](https://ar5iv.labs.arxiv.org/html/2109.01068)).

## 4. Avoiding BLURRY inpaint on thin bands

Generative nets (LaMa) shine on **large** holes but tend to soften thin slivers, because the band is small relative to the receptive field and the result gets downsampled-then-upsampled. Two levers:

- **Run the inpainter at near-native resolution on a tight crop around the band.** Don't feed the whole downscaled image; crop the edge neighborhood (band + a context margin), inpaint at full res, paste back. Smaller mask area = the net mostly *copies* surrounding texture instead of hallucinating, so it stays sharp.
- **For genuinely thin bands, classical propagation often beats a generative net.** Telea (fast-marching) and Navier-Stokes (PDE) **"work well for small, simple areas"** by propagating boundary color/gradients inward ([LearnOpenCV](https://learnopencv.com/image-inpainting-with-opencv-c-python/), [PyImageSearch](https://pyimagesearch.com/2020/05/18/image-inpainting-with-opencv-and-python/)). For a 2–6 px background-texture ribbon, that is sharper and artifact-free; their known failure mode (smearing) only shows up on *large* regions. Exemplar/patch-based (Criminisi-style, depth-guided) is the middle ground when the band has structured texture. **Thin bands inpaint sharper simply because there's less to invent**: most of the fill is determined by immediate neighbors.

---

## 5. Concrete recipe for your pipeline (per-pixel disparity + subject matte + LaMa)

**A. Build the thin, edge-localized disocclusion mask**
1. Smooth disparity `D` with a bilateral/median filter (sharpen soft edges). Compute `∇D` (Sobel) → magnitude `g` and direction.
2. Depth-edge set: `g > τ` (pick τ ~ a fraction of the global disparity range, e.g. top few %); CC-label, drop segments < 10 px.
3. Choose parallax vector `p` (your target view offset). For each edge pixel, keep only the **down-gradient side** (sign of `∇D · p` < 0) — the revealed side.
4. Band thickness per edge pixel: `w = clamp(round(|p| * (d_front − d_back)), 2, 8)`. Grow the mask from each edge into the far side by `w` (one-sided dilation along `−∇D`), **stopping at the foreground silhouette**. This is your thin disocclusion mask `B_mask`.

**B. Inpaint depth (far-constrained)**
5. Set `D` in `B_mask` by one-sided flood-fill/fast-march **from the far neighbors only**, clamped to ≈ `d_back`. Result: flat far depth, hard step at the foreground edge. (No front→back ramp.)

**C. Inpaint color sharply**
6. Crop a tight window = `B_mask ∪ (context margin ~ 1.5×w)` at **native resolution**.
7. If band is thin/texture-simple → `cv2.inpaint(..., INPAINT_TELEA)` (or NS). If band is wider or structured → run **LaMa on the crop only**, then paste back. Either way, never inpaint the whole downscaled frame.

**D. Crisp foreground matte + composite**
8. From your subject matte, make a narrow trimap (erode→255, dilate ring few px→127, else 0). Refine to soft alpha `A` via **guided filter** (small radius) or **FBA** (also gives decontaminated `F`).
9. Render: warp background layer (now with inpainted far depth + filled color) and warp foreground; composite
   `I_out = A·F + (1−A)·I_bg_warped`.
10. Optionally modulate `A` by the depth-edge visibility `exp(−β|∇D|²)` so partially-disoccluded edge pixels blend instead of haloing.

Net effect: the only pixels you invent are the few-pixel far-side ribbon actually uncovered by your small parallax; depth there is the true background depth; the foreground edge stays a crisp soft-alpha boundary with no dilated halo or light fringe.

**Sources:**
- [3D Photography using Context-aware Layered Depth Inpainting (CVPR 2020)](https://shihmengli.github.io/3D-Photo-Inpainting/) · [walkthrough](https://leeyngdo.github.io/blog/computer-vision/2023-12-31-3d-photography/) · [Casual GAN Papers](https://www.casualganpapers.com/single_view_layered_depth_3d_inpainting/3D-Inpainting-explained.html)
- [SLIDE: Single Image 3D Photography with Soft Layering and Depth-aware Inpainting (ICCV 2021)](https://ar5iv.labs.arxiv.org/html/2109.01068)
- [Spatio-temporal consistent DIBR using LDI and inpainting (EURASIP)](https://jivp-eurasipjournals.springeropen.com/articles/10.1186/s13640-016-0109-6)
- [F, B, Alpha Matting](https://arxiv.org/pdf/2003.07711) · [LearnOpenCV FBA writeup](https://learnopencv.com/image-matting-with-state-of-the-art-method-f-b-alpha-matting/)
- [Filter-based alpha matting for DIBR (guided filter / WGIF)](https://scispace.com/pdf/filter-based-alpha-matting-for-depth-image-based-rendering-38kzgj4r64.pdf)
- [Image Inpainting with OpenCV: Telea vs Navier-Stokes (LearnOpenCV)](https://learnopencv.com/image-inpainting-with-opencv-c-python/) · [PyImageSearch](https://pyimagesearch.com/2020/05/18/image-inpainting-with-opencv-and-python/)
