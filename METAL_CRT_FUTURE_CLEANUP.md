# 86Box Metal renderer — future cleanup once CRTEngine owns the signal chain

Architectural goal: a host should hand CRTEngine a framebuffer + the display it's
rendering to, and receive a finished, correctly-sampled CRT image. The host
should NOT know "the best way to feed the engine." Today the 86Box integration
carries several **host-side adaptations** that compensate for the engine not yet
doing this. Once those capabilities move into CRTEngine (from Phosphors), the
adaptations below should be **removed** from 86Box.

The ideal future bridge call is roughly:
`crt_bridge_render(device, framebuffer, contentRect, stride, drawable,
drawableSize, screen, time)` → engine does resolution selection, scan-doubling,
mask LOD, EDR, and the final display-resolution filtering internally.

## REMOVE from 86Box once CRTEngine handles it

All locations are in `src/qt/metal_presenter.mm` (host) or the bridge
`CRTEngine/Sources/CRTBridgeC/CRTBridge.swift`.

1. **Derivative-aware Gaussian downsample present shader** — `metal_presenter.mm`
   `kShaderSrc` `f_main` (the `fwidth`-based σ≈0.85·footprint Gaussian). This is
   the engine's job: CRTEngine should output a final image filtered to the
   display resolution (Phosphors' `compositeToScreen` / `DisplayRenderer` Gaussian
   does this). Then the host just blits the engine output 1:1 (or the engine
   renders straight into the drawable). → host present becomes a plain copy.

2. **Auto render-resolution selection** — bridge `recomputeLayout`:
   `pxPerScanline = max(2, ceil(dispH/scanlines))` and the derived
   `renderResolutionWidth`. Picking the phosphor buffer size from
   (mode × display) so scanlines resample cleanly is engine logic — the engine
   knows the scanline count and can be told the display size.

3. **`maskLODBias` computation** — bridge `recomputeLayout`
   `MaskLOD.bias(forRenderWidth:)`. Engine-internal; it knows its own render width.

4. **Scan-doubling** — bridge `multisyncScanlines` (`while lines < 350 { *=2 }`,
   200→400 / 240→480). This is VGA-monitor physics (low-res modes are
   double-scanned); belongs in CRTEngine's VGA/multisync path. Host should just
   pass the raw content resolution.

5. **EDR/brightness compensation** — bridge `applyDisplayEnvironment`
   (`edrBoost`, `stripeBrightnessBoost` via `EDRCompensation`). Engine should
   apply this internally given a `DisplayEnvironment`/`NSScreen`.

6. **Convergence resolution scaling** — bridge `applyConvergence`
   (`convergenceRaw * filter.pixelScale`). Engine-internal.

7. **Content sub-region staging copy** — `metal_presenter.mm` `presentCRT` blit
   from the 2048 staging texture into an exact content-sized texture (the engine
   currently expects input sized to the content). Engine should accept a
   sub-rect + stride directly.

8. **Host nearest-neighbour upscale of sub-native input** — `metal_presenter.mm`
   `presentCRT` (`kUpscaleTargetWidth`, the `scale`/`upW`/`upH` block +
   `contentPipeline`/`nearestSampler`). CRTEngine has no dedicated upscaler for
   input below the CRT signal resolution: its VGA encoder is a near-all-pass 5-tap
   at any magnification and the beam samples the encoded signal bilinearly, so a
   raw 640×480 frame becomes a 640→2880 bilinear stretch (soft edges, aperture-
   mask beating). Phosphors never hits this — it feeds ≥1080p, i.e. the engine is
   tuned only for the *downscale* regime. As a host workaround we integer
   nearest-upscale the framebuffer (~1920px wide) so the engine runs its
   well-tuned downscale path. **Move this into CRTEngine's input path** (a proper
   sub-native reconstruction, or an internal integer prescale keyed off the
   content/signal resolution) so hosts can hand raw pixels. NB: kept as *nearest*
   deliberately — any smoothing upscaler double-blurs against the CRT sim.
   (Deferred now because CRTEngine ships in Phosphors, currently in App Store
   review — engine left untouched.)

## KEEP host-side (legitimately the host's job — do NOT remove)

- `CAMetalLayer` on a child `NSView` + Qt `RendererCommon` plumbing
  (`qt_metalrenderer.*`) — window/surface ownership.
- Uploading 86Box's ARGB32 blit buffer into a Metal texture
  (`MetalPresenter::upload`) — host has the framebuffer.
- Aspect-fit / pillarbox into the window (`aspectFit`) — host owns the window
  geometry. (Could be delegated if the engine is told the target rect.)
- The "CRT Monitor Options" dialog + `NSUserDefaults` persistence
  (`qt_metalrenderer.mm` `getOptions`, presenter setters) — host UI.
- The renderer registration / lifecycle / per-frame drive
  (`qt_rendererstack` case, `onBlit`, present cadence).
- The sharpness-dial → falloff projection (`BeamSharpness.sigma/falloff`) is a
  UI mapping; may stay host-side or become an engine convenience.

## Net

After the engine owns 1–7, `metal_presenter.mm` shrinks to: upload framebuffer →
`crt_bridge_render(...)` with the drawable + screen → present. The bridge shrinks
to thin pass-throughs. That's the correct division: **host owns the window and the
pixels in; engine owns the entire CRT signal chain and the pixels out.**
