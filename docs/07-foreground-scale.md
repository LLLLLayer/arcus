# 07 — Foreground Scale: covering the disocclusion band (2026-06-08)

> Replaces the earlier **fgExtend** (alpha-ramp edge band) approach with a true **uniform scale-up of the
> whole subject**, pivoted at the subject centroid. PR: `feat/foreground-scale` (#1).

## Problem

When the camera moves, the warped foreground silhouette slides over the background and **reveals a thin
disoccluded band** just behind it. We fill that band (vertical-continuation / PatchMatch), but any fill is
imperfect — at high parallax the band reads as a smear of invented pixels around the subject.

## Two ways to attack it

| | **fgExtend (old)** | **fgScale (new)** |
|---|---|---|
| What it does | Bakes an alpha *ramp* outward from the silhouette (0→0.42), a shader threshold reveals more of that band | Scales the **entire foreground geometry** larger around the subject centroid |
| Visual | A feathered *halo* of nearest-subject color appears around the edge — looks like a sticker outline | The person is simply a little **bigger**; the enlarged real silhouette physically covers the band |
| Edge | Soft, semi-transparent ⇒ the fill behind still bleeds through | Hard, opaque real subject edge ⇒ nothing bleeds |
| User verdict | "没明白我的意思" — not what they wanted | "把它整体拉大" — this |

The key realization: **the user does not want to *grow the edge*, they want to *enlarge the object*.** Growing
the edge keeps the subject the same size and paints a band of (inevitably wrong) color around it. Enlarging the
object moves the *real* silhouette outward, so the genuine subject pixels — not invented ones — cover the
transition. This is the classic "cardboard-cutout slightly oversized" trick used in layered 3D-photo products.

## How it works

The foreground is a **cut mesh** (triangles kept only on/inside the subject silhouette). We scale its geometry
in the vertex shader, **before** the parallax warp, about the subject centroid `fgCenter` (uv):

```metal
float2 base = u.fgCenter + (uv0 - u.fgCenter) * u.fgScale;   // enlarge subject (pivot = centroid)
float2 uvW  = base + off * (d - u.depthPivot);               // then parallax warp
// texture is still sampled at uv0  ⇒  the subject MAGNIFIES, it does not translate
o.uv = uv0;
```

- **Texture sampled at `uv0`, geometry placed at `base`** → the triangle between two vertices stretches, so the
  subject's pixels are magnified. Edges stay sharp because the *alpha* matte is magnified too.
- **Only the foreground layer sets `fgScale`.** Background and mid layers keep `fgScale = 1`, so the scale term
  is the identity for them — the background does not move, only the subject grows over it.
- **Pivot = subject centroid**, computed in the bake as the mean (x,y) of subject-mask pixels, normalized to
  uv and carried on `Photo3DScene.fgCenter`. Scaling about the centroid grows the silhouette symmetrically in
  all directions, so the band is covered on every side, not just one.

### Why centroid, not image center
A portrait is rarely centered. Scaling about the image center would drift an off-center subject sideways (it
would *translate* as it grows). Scaling about the subject's own centroid keeps it locked in place and only
inflates it.

### Matte cleanup (the other half of the change)
With the band trick gone, the foreground matte goes back to a **clean hard threshold**
(`smoothstep(0.44, 0.56)` in the shader; baked alpha = the refined subject matte, no 0..0.42 ramp). The feather
band's *rgb* still uses nearest-subject color (`nearestValidFill(valid: subj)`) so that the 1px antialiased rim,
when enlarged, carries subject color rather than pulling a sliver of background color out. Net result: **zero
edge halo.**

## Uniforms layout

`MeshUniforms` grew from 48→56 bytes. `fgExtend(36)` became `fgScale(36)`; added `fgCenter` float2 at offset 48
(8-aligned after the `int debugMode` at 40). Swift and Metal offsets verified identical via
`MemoryLayout.offset(of:)` (0/8/16/20/24/28/32/36/40/48, stride 56).

## Tuning

- Slider **「前景放大」** maps `fgScale` 1.0–1.25, default **1.05** (subtle).
- 1.0 = original size (feature off). ~1.05–1.10 covers the band at typical parallax without the subject looking
  obviously oversized. Past ~1.15 a standing subject can start to look like it floats / clips head & feet at the
  frame edge (overscan crops it). The right value scales with `parallaxAmp` — more parallax reveals a wider
  band, wanting slightly more scale.

## Limitations / future

- It's a global scale, so it also enlarges the subject's *interior* (harmless) and pushes head/feet past the
  frame edge at high values. A future refinement: scale **anisotropically** or only enough to cover the measured
  band width (≈ `parallaxAmp` in uv), or even a **trailing-edge-only** push that grows the silhouette on the
  side the camera is moving away from (no rest-state size change). Deferred — the uniform scale is simple,
  predictable, and matches what the user asked for.
- Orthogonal to the *fill* quality: scale **hides** the band; a better inpainter (see `08-*`) would **fill** it.
  They compose — scale first to shrink the visible band, fill what's left.
