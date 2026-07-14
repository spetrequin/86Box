# CRTEngine's host contract, as verified in the source

Purpose: establish what CRTEngine actually requires of a display-only host, so the
86Box bridge can be refactored against **facts** rather than assumptions. Every claim
below is marked **VERIFIED** (read in the source, file:line given) or **UNKNOWN**.

Reference consumer: **Phosphors** — it ships, it looks correct, and it is therefore the
ground truth for "how you are supposed to drive this engine."

For each divergence the question **BRIDGE SIDE or ENGINE SIDE?** is left open — that is
Stephan's call, not an inference.

---

## 1. The frame path

**VERIFIED — `render()` returns the finished CRT image at PHOSPHOR-BUFFER resolution.**
`CRTFilter.render(inputTexture:time:commandBuffer:)` (`CRTFilter.swift:870`) runs the
phosphor simulation plus the display pass and returns the display texture. The display
texture is always the same size as the phosphor buffer — `resize()` reallocates both
together and the comment is explicit: "The display target shares the phosphor buffer's
size — they are the same canonical CRT image" (`CRTFilter.swift:920-939`).

**VERIFIED — `renderDisplay(to:)` is the RECORDING path, not the display path.**
"Render the display shader into a caller-provided texture at any resolution … a cheap
fragment-shader-only pass for **recording at a resolution different from the viewport**"
(`CRTFilter.swift:947-951`). It carries a recording-specific LOD bias (`:953-959`).
So `crt_bridge_render_display()` is not the call a display host should be reaching for.

**VERIFIED — the host is expected to composite the phosphor-res texture down to the
window.** Both hosts do this; it is the last stage and it is where they differ (§2).

## 2. THE COMPOSITE — the one hard structural divergence

**VERIFIED — Phosphors composites through CRTEngine.**
`compositeToScreen()` (`Phosphors/Rendering/Renderer+DrawLoop.swift:508-530`) sets the
viewport from `scalingManager.viewport` and draws a quad through the engine's
`scalingFragmentShader` (`Shaders.metal:567`), which calls `sampleScaledLinear`
(`Shaders.metal:539-561`): a 5×5 Gaussian whose step is half an output pixel, applied
**unconditionally, at every scale ratio**.

**VERIFIED — 86Box does NOT.** It composites with its own shader, `f_main`
(`src/qt/metal_presenter.mm:41-70`), invoked at `:424-426`. Two differences:

1. **An early-out CRTEngine does not have** (`metal_presenter.mm:52-53`):
   ```
   if (max(fp.x, fp.y) <= 1.0)
       return float4(tex.sample(s, in.uv).rgb, 1.0);   // plain bilinear, no filtering
   ```
   The premise is "footprint ≤ 1 means magnifying, so no aliasing." The phosphor buffer
   contains a **1-pixel-period mask and a scanline comb** — content sitting exactly at
   Nyquist. Point-sampling that at a footprint near 1.0 with an arbitrary fractional
   phase aliases regardless of whether we are technically magnifying.
2. **86Box ignores the engine's viewport** and re-derives its own aspect-fit rect
   (`aspectFit`, `metal_presenter.mm:272-281`, used at `:424`), duplicating
   `ScalingManager.calculateViewport()` (`ScalingManager.swift:240-264`).

**HYPOTHESIS, NOT VERIFIED:** the early-out is what produces the artifact pattern (which
Stephan reports is visible in triode too — consistent, since the scanline comb aliases
with no mask present). Testable by logging the actual footprint. NOT yet done.

> **BRIDGE SIDE or ENGINE SIDE?** Options: (a) the bridge exposes CRTEngine's composite
> (`scalingVertexShader`/`scalingFragmentShader`) so the host draws through the engine —
> mirrors Phosphors exactly, deletes `f_main` and `aspectFit`; or (b) CRTEngine grows a
> "present into this drawable" entry point and owns the whole tail.

## 3. COLOUR — the transfer functions do not match on the SDR path

**VERIFIED — the engine expects GAMMA-ENCODED input.** The phosphor kernel linearises
internally: `pow(max(effectiveIntensity, 0), 2.2)` (`PhosphorSimulation.h:742`). 86Box
feeds raw 8-bit framebuffer values (`BGRA8Unorm`, `metal_presenter.mm:353-358`), which
are gamma-encoded. **The feed is correct — no change needed.**

**VERIFIED — the engine's output is LINEAR.** "Live-preview compositor. Writes LINEAR
values; the screen drawable is rgba16Float (HDR-capable), so the OS / EDR display takes
care of tonemapping above SDR white … No in-shader tonemap" (`Shaders.metal:563-566`).

**VERIFIED — Phosphors always presents into a linear float drawable.**
`metalKitView.colorPixelFormat = .rgba16Float` (`Phosphors/Rendering/Renderer.swift:332`)
and `metalLayer.wantsExtendedDynamicRangeContent = true`
(`Phosphors/App/GameViewController.swift:39`). Unconditionally. There is no SDR path.

**VERIFIED — 86Box has an SDR path that Phosphors does not**
(`metal_presenter.mm:655,664-665`):
```objc
MTLPixelFormat desired = edr ? MTLPixelFormatRGBA16Float : MTLPixelFormatBGRA8Unorm;
impl->layer.colorspace = CGColorSpaceCreateWithName(
    edr ? kCGColorSpaceExtendedLinearDisplayP3 : kCGColorSpaceDisplayP3);
```
When EDR headroom ≤ 1.05 we write the engine's **linear** output into an **8-bit layer
tagged DisplayP3**, a gamma-encoded colour space. Linear light presented as though it
were gamma-encoded reads **dark**, with crushed midtones — and no brightness/contrast
slider can correct it, because it is a transfer-function mismatch, not a gain error.

**UNKNOWN:** whether the SDR path is actually active on Stephan's MacBook Pro (i.e.
whether `edrCurrent` reports ≤ 1.05 in normal use). One log line settles it. This is the
strongest candidate for "the image is very dark and hard to dial in" and it is NOT the
`EDRCompensation` formula, which is a separate (real, but secondary) issue.

> **BRIDGE SIDE or ENGINE SIDE?** Options: (a) the host always uses `rgba16Float` +
> extended-linear, exactly like Phosphors, and the SDR branch is deleted; or (b) the
> engine gains an "encode for an SDR target" output mode so any host can present to an
> 8-bit drawable.

## 4. What the engine already owns (and the bridge still second-guesses)

**VERIFIED — one-call bring-up exists.** `configure(preset:phosphor:layout:contentSize:
displayRefreshRate:patternScale:)` (`CRTFilter+ApplyPreset.swift:216-227`) = applyPreset
+ displayRefreshRate + apply(layout). The bridge instead calls `applyPreset` and then
pokes `timing.scanRate`, `timing.crtRefreshRate`, `timing.scanlineCount` and the VGA
encoder by hand (`CRTBridge.swift` `applyPresetInternal`).

**VERIFIED — the engine owns mask LOD.** `maskLODBias` is engine-derived (commit
`9565ea1`), yet the bridge still computes `MaskLOD.bias(forRenderWidth:)` itself.

**VERIFIED — the engine owns the render-resolution decision for `.displayOnly`**
(`ScalingManager.swift:308-311`, D2), yet the bridge still computes the content width and
passes `renderResolutionWidth` explicitly.

**VERIFIED — the engine owns the viewport** (`ScalingManager.swift:240-264`), yet the
bridge/host re-derive it (§2).

> **BRIDGE SIDE or ENGINE SIDE?** These are all "the host is deciding something the
> engine already decides." The stated north star (`docs/RenderIntent-DisplayVsRecording.md`
> §1) says the host makes ZERO rendering decisions — but each removal is still a choice
> about how much the engine's API should carry.

## 5. Two calculations that must be right for 86Box (Stephan's requirement)

86Box is **display-only**. There is no movie resolution to balance against, unlike
Phosphors (which balances mask pitch between the recording resolution and the display so
the user gets no surprises when they record). So:

1. **RGB pattern pitch — from the DISPLAY resolution only.** It must not react to the
   emulated card's mode. **VERIFIED problem:** the `.displayOnly` pitch is specified in
   *panel pixels* (`ScalingManager.swift:354-367`) but is drawn into a phosphor buffer
   whose width is derived from the scanline-snapped height (`:317-321`) — so the signal's
   line count silently rescales the grid the mask lands on.
2. **Beam height/spacing — from the signal's scanline count against what the panel can
   resolve.** `signalSpacing = phosphorHeight / scanlineCount`, beam σ via
   `BeamSharpness` with a Nyquist floor (`ScalingManager.swift:415-421`).

**CAUTION, learned the hard way:** naively making the phosphor buffer take the panel's
pixel grid (dropping the integer scanline snap) produced scanline artifacts visible even
in triode. The snap is doing something load-bearing that is **NOT YET UNDERSTOOD**. It
must be understood before it is touched again.

---

## Summary of what is actually established

| # | Finding | Status |
|---|---|---|
| 1 | Engine expects gamma-encoded input; 86Box's feed is correct | VERIFIED — no change |
| 2 | Engine's output is LINEAR | VERIFIED |
| 3 | 86Box's SDR drawable is 8-bit + gamma colour space → linear-into-encoded mismatch → dark | VERIFIED (mismatch); UNKNOWN whether active at runtime |
| 4 | 86Box replaced the engine's composite with `f_main`, which point-samples at footprint ≤ 1 | VERIFIED (divergence); HYPOTHESIS (that it causes the pattern) |
| 5 | Bridge duplicates decisions the engine already owns (LOD, render width, viewport, timing) | VERIFIED |
| 6 | Phosphor buffer width is derived from the signal's scanline count, so the mode rescales the mask's grid | VERIFIED |
| 7 | Why the integer scanline snap is load-bearing | **UNKNOWN — do not touch until understood** |
