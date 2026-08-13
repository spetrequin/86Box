//
//  CRTBridge.swift — flat C ABI over CRTEngine.
//
//  Exposes the minimum surface an emulator frontend (e.g. an 86Box Qt renderer)
//  needs: create a filter, pick a preset, hand in a Metal texture per frame, get
//  a simulated texture back. Every entry point is an @_cdecl symbol matching
//  crt_bridge.h, so a clang/Obj-C++ translation unit can drive the
//  (compiled-Swift) engine with no Swift toolchain on the calling side.
//
//  Metal objects cross as raw pointers. An id<MTLDevice> handed over from
//  Obj-C as (__bridge void *) is an unretained pointer to a live Obj-C object;
//  we recover the Swift protocol value with Unmanaged + a protocol cast.
//
//  Shaders + presets load from CRTEngine's own resource bundle (Bundle.module).
//  86Box bundles that resource bundle (with a compiled default.metallib) into its
//  .app, so CRTEngine is used completely unmodified.
//

import Foundation
import AppKit
import Metal
import CRTEngine

// MARK: - Pointer bridging helpers

@inline(__always)
private func object<T>(_ ptr: UnsafeMutableRawPointer, as _: T.Type) -> T? {
    // The pointer refers to a live Obj-C object the host still owns; borrow it.
    return Unmanaged<AnyObject>.fromOpaque(ptr).takeUnretainedValue() as? T
}

// MARK: - Bridge state

/// One live engine: the filter plus the scaling/layout it needs to size itself.
private final class CRTBridgeState {
    let device: MTLDevice
    let filter: CRTFilter
    var scaling: ScalingManager
    var preset: CRTPreset?
    var phosphor: PhosphorPreset?
    var contentSize: SIMD2<Int> = SIMD2(640, 480)
    /// Vertical refresh of the SIGNAL the emulated card is sending, as reported by
    /// its CRTC (crt_bridge_set_signal). This is what the tube locks to and times its
    /// beam against — NOT the host display's refresh (that is `filter.displayRefreshRate`,
    /// set by crt_bridge_set_display_refresh). Keep the two straight.
    /// 0 = the card did not report it; fall back to the standards table.
    var signalRefreshHz: Float = 0
    var drawableSize: CGSize = CGSize(width: 0, height: 0)
    /// USER override of the phosphor-buffer render width (px). 0 = let CRTEngine decide,
    /// which is the normal case: render resolution is engine policy for a display-only
    /// host (D2 — the engine sizes it from its own viewport). Non-zero only if the host
    /// explicitly pins it via crt_bridge_set_render_resolution.
    var renderWidthOverride: Int = 0
    /// `.displayOnly` RGB mask scale (Pattern Scale) — a multiplier of the tube's PHYSICAL
    /// phosphor pitch. 1.0 (default) = the real pitch; higher coarsens the grille so it reads
    /// at smaller window sizes. CRTEngine 1.4.0 supports 1–10×. Set via crt_bridge_set_mask_scale;
    /// the CRT_MASK_SCALE env var seeds it. See CRTEngine docs/RenderIntent-DisplayVsRecording.md.
    var displayMaskScale: Float =
        Float(ProcessInfo.processInfo.environment["CRT_MASK_SCALE"] ?? "") ?? 1.0
    /// Host override of the preset's phosphor pattern (nil = use preset).
    var patternOverride: Int? = nil
    /// Host sharpness dial [0=soft … 1=sharp] (nil = use preset's beam falloff).
    /// Converted to beamFalloff per-layout so it's perceptually linear and
    /// resolution-aware (Phosphors does the same projection).
    var sharpnessOverride: Float? = nil
    /// User convergence in [-10, 10] (bipolar; sign = fringing direction). Stored
    /// raw and scaled by pixelScale at apply time, so it tracks render resolution.
    var convergenceRaw: Float = 0
    // Directly-set picture/beam/condition overrides. nil = keep the preset's
    // value. Re-applied after every applyPreset (which a mode change re-runs),
    // so user settings survive 86Box resolution switches.
    var brightnessOverride:   Float? = nil
    var contrastOverride:     Float? = nil
    var edgeFocusOverride:    Float? = nil
    var bloomOverride:        Float? = nil
    var hJitterOverride:      Float? = nil
    var vJitterOverride:      Float? = nil
    var shotNoiseOverride:    Float? = nil
    var signalNoiseOverride:  Float? = nil
    var hBandwidthOverride:   Float? = nil   // raised-cosine rolloff β (video bandwidth)
    var hFocusOverride:       Float? = nil   // optical horizontal focus σ (source px)
    var scanSmoothOverride:   Float? = nil   // scanline gap-fill strength (band-limit)
    var patternSmoothOverride: Float? = nil  // mask anti-alias strength (band-limit margin)
    var beamSegmentOverride:  Float? = nil   // beam temporal resolution (1 = legacy whole-line, <1 = segmented dot)
    var shutterOverride:      Float? = nil   // observer integration (1 = fused eye, <1 = camera shutter)
    let displayEnv = DisplayEnvironment()

    /// The engine's display tail (band-limited scale + the drawable's transfer function).
    /// Rebuilt when the drawable's pixel format or transfer changes — e.g. the window moves
    /// to an EDR display and the host swaps the layer from bgra8Unorm to rgba16Float.
    var compositor: DisplayCompositor? = nil
    /// Viewport-sized intermediate that the 1.4.0 display shader renders into — the RGB mask
    /// is evaluated at OUTPUT (on-screen) resolution here, so it stays sharp at any window
    /// size instead of being baked into the phosphor buffer and upscaled. The compositor
    /// then places it (aspect) and applies the drawable's transfer. Resized with the viewport.
    var displaySurface: MTLTexture? = nil

    init(device: MTLDevice, filter: CRTFilter, scaling: ScalingManager) {
        self.device = device
        self.filter = filter
        self.scaling = scaling
    }
}

/// Scanline count of the signal on the wire. A multisync monitor paints exactly the
/// raster it is sent, so this is simply the content height.
///
/// It does NOT scan-double. Scan-doubling is the VIDEO CARD's job: a VGA card running
/// a 200-line mode re-times it to 400 lines (CRTC `crtc[9]` bit 7) before it reaches
/// the cable, so the monitor never sees a 200-line VGA signal. 86Box models this
/// (`svga->linedbl`), so the raster arriving here is already doubled. Doubling again
/// here would be a second, bogus doubling by a device that has no business doing it.
/// A genuinely 200-line signal (a real CGA card) is painted as 200 lines — which is
/// what a CGA monitor did.
///
/// A fixed-frequency tube has one raster it can paint, so it uses the preset's count.
private func signalScanlines(_ preset: CRTPreset, _ contentH: Int) -> Int {
    guard preset.multiSync else { return preset.scanlineCount }
    return max(1, min(contentH, 2048))   // sanity bounds only — no reshaping
}

/// Vertical refresh (Hz) of the signal on the wire.
///
/// A multisync monitor has no rate of its own — it LOCKS TO THE SIGNAL — so the rate
/// comes from the card, never from the preset. 86Box reports its real CRTC-derived
/// refresh via crt_bridge_set_signal (mon_signal_refresh_hz), and that always wins:
/// a card does not guess its own timing, it *is* the timing.
///
/// When the card DOESN'T report (CGA/MDA/EGA keep their timings in their own structs and
/// are not wired up yet), fall back to the PRESET's refresh — the CRT settings are the
/// defaults for when there is no request from the API. This replaces a fabricated
/// `contentH < 480 ? 70 : 60` guess: a real number the user chose beats an invented one,
/// and it is what makes the flexible monochrome monitors honour their JSON default rate
/// (e.g. amber's 70 Hz) instead of a resolution-based guess. Fixed-frequency presets (TVs)
/// keep their own physical rate via the `multiSync` guard.
private func signalRefreshHz(_ state: CRTBridgeState,
                             _ preset: CRTPreset,
                             _ contentH: Int) -> Float {
    guard preset.multiSync else { return preset.refreshRate }
    if state.signalRefreshHz > 0 { return state.signalRefreshHz }   // the card's truth
    return preset.refreshRate                                       // JSON default, not a guess
}

/// Active phosphor pattern: host override if set, else the preset's.
private func effectivePattern(_ state: CRTBridgeState) -> Int32 {
    Int32(state.patternOverride ?? state.preset?.colorPhosphorPattern ?? 0)
}

/// Convergence is specified in 1920-px-reference units; scale to the actual
/// phosphor render resolution (Phosphors does the same with `resScale`).
private func applyConvergence(_ state: CRTBridgeState) {
    state.filter.parameters.beam.beamConvergence = state.convergenceRaw * state.filter.pixelScale
}

/// Re-apply every directly-set user override over the freshly-applied preset.
/// Called after applyPreset (incl. on mode changes) so user picture/beam/condition
/// adjustments aren't reset to preset defaults. (pattern/falloff/convergence are
/// re-applied separately via the layout path.)
private func applyUserOverrides(_ state: CRTBridgeState) {
    if let v = state.brightnessOverride  { state.filter.parameters.display.brightness = v }
    if let v = state.contrastOverride    { state.filter.parameters.display.contrast = v }
    if let v = state.edgeFocusOverride   { state.filter.parameters.beam.edgeFocusDegradation = v }
    if let v = state.bloomOverride        { state.filter.parameters.beam.dynamicBloomStrength = v }
    if let v = state.hJitterOverride      { state.filter.parameters.aging.horizontalInstability = v }
    if let v = state.vJitterOverride      { state.filter.parameters.aging.verticalInstability = v }
    if let v = state.shotNoiseOverride    { state.filter.parameters.beam.beamShotNoise = v }
    if let v = state.signalNoiseOverride  { state.filter.parameters.aging.signalNoise = v }
    if let v = state.hBandwidthOverride   { state.filter.parameters.beam.beamHorizontalRolloff = v }
    if let v = state.hFocusOverride       { state.filter.parameters.beam.beamHorizontalSpot = v }
    if let v = state.scanSmoothOverride   { state.filter.parameters.beam.scanlineBandLimit = v }
    if let v = state.patternSmoothOverride { state.filter.parameters.display.maskSmoothing = v }
    // The beam is pinned to the DOT (its physical truth) unless a host has
    // explicitly overridden it via crt_bridge_set_beam_segment (kept for ABI
    // compat / diagnostics; the 86Box UI no longer exposes it).
    state.filter.parameters.beam.beamSegmentFraction = state.beamSegmentOverride ?? 0.0
    // (The emitter lattice this used to gate was deleted from CRTEngine
    // 2026-08-12, commit a735bec — it was dormant machinery, never reachable
    // from any host. `PhosphorParameters.latticeEnabled` no longer exists.)
    if let v = state.shutterOverride      { state.filter.parameters.display.observerShutter = v }
}

/// Push host-display capabilities into the filter: refresh cadence and the LIVE
/// EDR headroom. EDR is no longer a gain — the engine's highlight shoulder gives
/// the tube's >1.0 peaks room up to min(peakAllowance, this headroom), and moving
/// the window to an SDR panel instantly degrades to the SDR curve.
private func applyDisplayEnvironment(_ state: CRTBridgeState) {
    let env = state.displayEnv
    state.filter.displayRefreshRate = Float(env.info.maxRefreshRate)
    state.filter.displayHeadroom = Float(env.edrCurrent)

    // NOTE: stripeBrightnessBoost is no longer set here. As of CRTEngine 1.4.0 the
    // energy-preserving mask (mask ÷ tile-mean) keeps brightness constant by construction,
    // so the old 1/3-active-phosphor compensation is a dead no-op in the display shader
    // (it survives only in comments there).
}

// MARK: - Internal helpers

private func applyPresetInternal(_ state: CRTBridgeState,
                                 preset: CRTPreset,
                                 phosphor: PhosphorPreset,
                                 content: SIMD2<Int>) {
    state.preset = preset
    state.phosphor = phosphor
    state.contentSize = content

    // Multisync: the tube paints the raster it is sent, so the scanline structure is
    // the signal's own line count. CRTEngine is used unmodified, so we apply the
    // preset normally and then set the scanline count directly on the public timing
    // parameters (the VGA encoder keeps the preset's max-output budget, which is fine).
    let scanlines = signalScanlines(preset, content.y)
    // Signal refresh tracks the mode for multisync monitors (e.g. 70 Hz for VGA
    // 720×400 text, 60 Hz for 640×480+); fixed-freq tubes keep the preset's rate.
    let refreshHz = signalRefreshHz(state, preset, content.y)
    state.filter.applyPreset(preset, phosphor: phosphor, contentSize: content)
    state.filter.parameters.timing.scanRate = refreshHz
    state.filter.parameters.timing.crtRefreshRate = refreshHz
    state.filter.parameters.timing.interlaced = preset.interlaced
    state.filter.parameters.timing.scanlineCount = Int32(scanlines)

    // Point the VGA encoder at the ACTUAL signal — the card knows its mode, so the
    // preset's default resolution is overridden. The encode then runs 1:1 and every
    // sample the card sent survives to the beam.
    //
    // The width must come from the SIGNAL, not from the tube's aspect ratio. The
    // preset-driven `configureMaxOutput` derives width as scanlineCount × 4/3, which is
    // right for the 4:3 graphics modes by coincidence (480×4/3 = 640, 600×4/3 = 800,
    // 768×4/3 = 1024) and wrong for the text modes, which have NON-SQUARE pixels: DOS
    // text is 720×400, and 400×4/3 = 533 — so a quarter of the horizontal detail was
    // resampled away before the beam ever saw the signal, and 9px character cells went
    // soft. The non-square aspect is real and is resolved where a real monitor resolves
    // it: when the beam paints the signal across the 4:3 glass.
    //
    // `scanlines` is the signal's line count for a multisync tube, or the preset's fixed
    // raster for a fixed-frequency tube — the raster the beam actually paints.
    if state.filter.isVGAPipeline {
        state.filter.vgaEncoder?.configureSignalResolution(width: content.x,
                                                           height: scanlines,
                                                           refreshRate: refreshHz)
        state.filter.vgaEncoder?.configure(sourceWidth: content.x,
                                           sourceHeight: content.y,
                                           refreshRate: refreshHz)
    }

    // Stripe(1)/slot(3) masks carry a pure-primary RGB carrier that rainbows on
    // resample; the chroma notch collapses it toward neutral. (Phosphors sets 1.0.)
    let pattern = effectivePattern(state)
    state.filter.parameters.display.chromaNotchStrength =
        (pattern == 1 || pattern == 3) ? 1.0 : 0.0

    state.scaling = ScalingManager(scanlineCount: scanlines,
                                   aspectRatio: 4.0 / 3.0)
    state.scaling.enforceAspectRatio = true
    state.scaling.interlaced = preset.interlaced
    recomputeLayout(state)
    // Pattern just changed (via the layout) → recompute EDR/stripe compensation.
    applyDisplayEnvironment(state)
    // Re-apply user picture/beam/condition overrides over the preset defaults.
    applyUserOverrides(state)
}

/// DIAGNOSTIC (temporary): record the layout the engine actually chose.
///
/// The existing log carries the SIGNAL and the DISPLAY but not the DECISION, which left the
/// interesting numbers — the phosphor buffer, the buffer→viewport ratio, and above all the
/// scanline pitch as it lands ON THE GLASS — to be guessed at from screenshots. They are not
/// guessable: a screenshot is resampled on the way to being viewed, which manufactures
/// exactly the kind of beat we are chasing. Same file as the host's signal/display lines
/// (a Finder-launched .app has nowhere to put stderr).
private func logLayout(_ state: CRTBridgeState,
                       _ l: CRTScreenLayout,
                       _ panelScale: Float) {
    guard let home = ProcessInfo.processInfo.environment["HOME"],
          let f = FileHandle(forWritingAtPath: home + "/Library/Logs/86Box-crt-signal.log")
    else { return }
    defer { try? f.close() }
    f.seekToEndOfFile()

    let vpH = Float(l.viewport.height)
    let vpW = Float(l.viewport.width)
    // THE number: scanline pitch on the panel. The phosphor buffer cancels out of it
    // (k·vpH / k·scanlines), so this is what the beat — if any — has to be explained by.
    let displayedPitch = vpH / Float(max(1, l.scanlineCount))
    // Buffer→viewport ratio. 1.0 = no resample; anything else resamples the comb + mask.
    let ratio = vpH / Float(max(1, l.phosphorHeight))
    // Displayed RGB stripe width in drawable px (what the mask actually looks like).
    let displayedStripe = l.stripePitch * vpW / Float(max(1, l.phosphorWidth))

    let line = String(
        format: "layout -> signal %dx%d%@ | drawable %.0fx%.0f | viewport %.0fx%.0f"
              + " | buffer %dx%d (k=%.3f) | displayedPitch %.4f px/scanline"
              + " | buf->vp %.5f | renderW %d | beamW %.3f vis %.3f"
              + " | stripePitch %.3f buf -> %.3f px | panelScale %.4f\n",
        state.contentSize.x, l.scanlineCount, l.interlaced ? " INTERLACED" : "",
        Float(state.drawableSize.width), Float(state.drawableSize.height),
        vpW, vpH,
        l.phosphorWidth, l.phosphorHeight,
        Float(l.phosphorHeight) / Float(max(1, l.scanlineCount)),
        displayedPitch, ratio, l.renderWidth,
        l.beamWidth, l.scanlineVisibility,
        l.stripePitch, displayedStripe, panelScale)
    f.write(Data(line.utf8))
}

private func recomputeLayout(_ state: CRTBridgeState) {
    guard let preset = state.preset,
          state.drawableSize.width > 0, state.drawableSize.height > 0 else { return }
    _ = state.scaling.updateDrawableSize(state.drawableSize)
    let scanlines = signalScanlines(preset, Int(state.contentSize.y))

    // Panel-anchored pitch is gone from CRTEngine: `DisplayInfo.nativePixelWidth`
    // (the field this used to read) was deleted 2026-08-12/13 along with the rest
    // of the panel-PPI model — stripe pitch is now derived purely from the preset's
    // physical tube geometry (tvSizeInches × phosphorPitchMM), never host PPI. The
    // `CRTLayoutInputs.backingToPanelScale` parameter below is consequently orphaned
    // (no reader left in ScalingManager, verified by grep) but is kept at its
    // identity value since the struct still declares it.
    let panelScale: Float = 1.0

    // Build the layout with the preset's beam, then — only if the user moved the
    // sharpness dial — rebuild it with the mapped falloff.
    //
    // The dial is a perceptually-linear UI mapping onto a Gaussian σ anchored to the
    // SCANLINE CELL, so the full travel stays useful at any resolution (raw beamFalloff
    // is wildly non-linear; all the visible change lives in ~0.7…0.9). That mapping needs
    // the scanline spacing — which is the ENGINE's number, not ours. So we ask the engine
    // for a layout, read `pixelsPerScanline` off it, and map against that. The bridge used
    // to estimate the spacing itself from a render width it also computed itself; both are
    // engine decisions, and re-deriving them here is exactly how the two drift apart.
    // computeLayout is pure arithmetic, so the second pass is free.
    func layout(beamFalloff: Float) -> CRTScreenLayout {
        state.scaling.computeLayout(makeInputs(state, preset, scanlines, beamFalloff, panelScale))
    }
    var chosen = layout(beamFalloff: preset.beamFalloff)
    if let s = state.sharpnessOverride {
        let spacing = max(2.0, chosen.pixelsPerScanline)
        let sigma = BeamSharpness.sigma(forSharpness: s, scanlineSpacing: spacing)
        chosen = layout(beamFalloff: BeamSharpness.falloff(forSigma: sigma, scanlineSpacing: spacing))
    }

    state.scaling.applyLayoutState(chosen)
    // Pattern Scale (RGB mask coarsening) rides the engine's `patternScale` argument here —
    // it multiplies the layout's physical stripe pitch (CRTFilter+ApplyPreset), exactly as
    // Phosphors does. (The CRTLayoutInputs.displayMaskScale field is orphaned in 1.4.0: the
    // physical-density refactor stopped reading it, so setting it in makeInputs did nothing —
    // which is why the slider was inert until this call started passing patternScale.)
    state.filter.apply(chosen, patternScale: state.displayMaskScale)
    logLayout(state, chosen, panelScale)

    // NOT set here any more: maskLODBias. `filter.apply(layout)` derives it from the
    // layout's render width (engine policy, MaskLOD) — the bridge was recomputing the
    // identical number and pushing it straight back in.

    // Re-apply convergence — pixelScale tracks the engine's render resolution, and
    // apply(layout) can reset beam params. Keeps the user's setting consistent.
    // (Still host-side: the engine takes convergence in phosphor pixels, so someone has
    // to scale the user's resolution-independent value. Engine-side would be better —
    // METAL_CRT_FUTURE_CLEANUP item 6.)
    applyConvergence(state)
}

/// The facts the engine needs to decide a layout. Everything here is either a SIGNAL fact
/// (scanline count, interlace), a PRESET fact (tube geometry, phosphor), a DISPLAY fact
/// (drawable size, panel scale), or a USER choice (pattern, mask scale). Nothing here is a
/// rendering decision — those belong to CRTEngine.
private func makeInputs(_ state: CRTBridgeState,
                        _ preset: CRTPreset,
                        _ scanlines: Int,
                        _ beamFalloff: Float,
                        _ panelScale: Float) -> CRTLayoutInputs {
    CRTLayoutInputs(
        scanlineCount: scanlines,
        aspectRatio: 4.0 / 3.0,
        drawableSize: state.drawableSize,
        enforceAspectRatio: true,
        interlaced: preset.interlaced,
        beamFalloff: beamFalloff,
        phosphorMode: Int32(preset.phosphorMode),
        // Phosphor pattern: host override (picker) if set, else the preset's
        // (0=triode, 1=stripe/aperture grille, 2=shadow mask, 3=slot).
        colorPhosphorPattern: effectivePattern(state),
        // Physical screen geometry comes from the preset, not hardcoded guesses —
        // these drive the stripe/mask pitch. (Was 14"/0.25mm/1.0.)
        tvSizeInches: preset.tvSizeInches,
        phosphorPitchMM: preset.phosphorPitchMM,
        phosphorMagnification: preset.phosphorMagnification,
        // RENDER RESOLUTION IS THE ENGINE'S DECISION (D2). 0 = "you decide": for
        // .displayOnly the engine sizes the phosphor buffer from its own viewport
        // (ScalingManager.autoDisplayRenderWidth). The bridge used to compute the
        // aspect-fitted content width and call that policy itself — deciding, with extra
        // steps. `renderWidthOverride` is non-zero only when the user pins it explicitly
        // (crt_bridge_set_render_resolution).
        renderResolutionWidth: state.renderWidthOverride,
        // minStripePixels is currently unread inside computeStripePitch on ANY
        // renderIntent (`_ = minStripePixels // unused here for now` —
        // ScalingManager.swift; stripe coarsening-to-a-floor is a deliberate
        // later step) — 2.0 is the resample-safe value to have wired through
        // once that lands.
        minStripePixels: 2.0,
        // 86Box presents 1:1 to a physical panel and never records — display-only. There
        // is no movie resolution to balance the mask against, unlike Phosphors.
        renderIntent: .displayOnly,
        // Orphaned in current CRTEngine (no reader in ScalingManager — the panel-PPI
        // pitch model this fed was removed 2026-08-12/13). Kept at identity; see
        // `panelScale` above.
        backingToPanelScale: panelScale,
        // Scanline anti-alias strength: the sharp half also relaxes the engine's
        // display-domain beam-sigma floor (tight beam + raw comb, user's alias risk).
        scanlineSmoothing: state.scanSmoothOverride ?? 1.0
        // NOTE: displayMaskScale is NOT passed — it's orphaned in CRTEngine 1.4.0 (stored,
        // never read). Pattern Scale is applied via filter.apply(patternScale:) in recomputeLayout.
    )
}

// MARK: - C ABI: creation

@_cdecl("crt_bridge_create")
public func crt_bridge_create(_ devicePtr: UnsafeMutableRawPointer,
                              _ phosphorW: Int32,
                              _ phosphorH: Int32) -> UnsafeMutableRawPointer? {
    return makeBridge(devicePtr, phosphorW, phosphorH)
}

private func makeBridge(_ devicePtr: UnsafeMutableRawPointer,
                        _ phosphorW: Int32,
                        _ phosphorH: Int32) -> UnsafeMutableRawPointer? {
    guard let device = object(devicePtr, as: MTLDevice.self) else {
        NSLog("[CRTBridge] create: not an MTLDevice")
        return nil
    }
    guard let filter = CRTFilter(device: device,
                                 width: Int(phosphorW), height: Int(phosphorH)) else {
        NSLog("[CRTBridge] create: CRTFilter init failed (shader bundle/metallib?)")
        return nil
    }
    let scaling = ScalingManager(scanlineCount: 480, aspectRatio: 4.0 / 3.0)
    let state = CRTBridgeState(device: device, filter: filter, scaling: scaling)
    state.filter.resize(width: Int(phosphorW), height: Int(phosphorH))
    return Unmanaged.passRetained(state).toOpaque()
}

// MARK: - C ABI: preset selection

@_cdecl("crt_bridge_apply_preset")
public func crt_bridge_apply_preset(_ ref: UnsafeMutableRawPointer,
                                    _ namePtr: UnsafePointer<CChar>,
                                    _ contentW: Int32,
                                    _ contentH: Int32) -> Bool {
    let state = Unmanaged<CRTBridgeState>.fromOpaque(ref).takeUnretainedValue()
    let name = String(cString: namePtr)
    guard let loaded = PresetLoader.loadPresets(),
          let preset = loaded.crts.first(where: { $0.name == name }) else {
        NSLog("[CRTBridge] apply_preset: preset '%@' not found", name)
        return false
    }
    applyPresetInternal(state, preset: preset,
                        phosphor: loaded.phosphors[preset.phosphorIndex],
                        content: SIMD2(Int(contentW), Int(contentH)))
    return true
}

/// Switch to a different CRT preset at runtime, at the CURRENT content size, keeping
/// the user's live overrides (applyPresetInternal re-applies them). For the options
/// UI's preset picker. Returns false if the name is unknown.
@_cdecl("crt_bridge_set_preset")
public func crt_bridge_set_preset(_ ref: UnsafeMutableRawPointer,
                                  _ namePtr: UnsafePointer<CChar>) -> Bool {
    let state = Unmanaged<CRTBridgeState>.fromOpaque(ref).takeUnretainedValue()
    let name = String(cString: namePtr)
    guard let loaded = PresetLoader.loadPresets(),
          let preset = loaded.crts.first(where: { $0.name == name }) else {
        NSLog("[CRTBridge] set_preset: preset '%@' not found", name)
        return false
    }
    applyPresetInternal(state, preset: preset,
                        phosphor: loaded.phosphors[preset.phosphorIndex],
                        content: state.contentSize)
    return true
}

// MARK: - C ABI: dynamic state

/// Re-apply the current preset at a new emulated resolution (86Box mode change).
/// Prefer crt_bridge_set_signal, which carries the refresh too; this leaves the
/// refresh at whatever was last reported.
@_cdecl("crt_bridge_set_content_size")
public func crt_bridge_set_content_size(_ ref: UnsafeMutableRawPointer,
                                        _ contentW: Int32,
                                        _ contentH: Int32) {
    let state = Unmanaged<CRTBridgeState>.fromOpaque(ref).takeUnretainedValue()
    guard let preset = state.preset, let phosphor = state.phosphor else { return }
    applyPresetInternal(state, preset: preset, phosphor: phosphor,
                        content: SIMD2(Int(contentW), Int(contentH)))
}

/// THE SIGNAL ON THE WIRE — one atomic description of what the emulated card is
/// sending: active resolution and the card's true vertical refresh (from its CRTC).
///
/// This is the whole cable. It is one-way, exactly like VGA: the card pushes, the
/// tube reacts. Nothing is reported back, because a monitor has no way to talk to a
/// video card. The bridge's job is only to be an HONEST card — real timings, no
/// invention — and CRTEngine's job is to respond correctly to whatever arrives.
///
/// Resolution and refresh change together on a mode switch, so they are set together;
/// setting them in two calls would leave the engine briefly timed against the old
/// mode's rate at the new mode's resolution.
///
/// `refreshHz` = 0 means the card doesn't report its timing (CGA/MDA/EGA today) —
/// the bridge then falls back to the VGA standards table.
@_cdecl("crt_bridge_set_signal")
public func crt_bridge_set_signal(_ ref: UnsafeMutableRawPointer,
                                  _ activeW: Int32,
                                  _ activeH: Int32,
                                  _ refreshHz: Float) {
    let state = Unmanaged<CRTBridgeState>.fromOpaque(ref).takeUnretainedValue()
    guard let preset = state.preset, let phosphor = state.phosphor else { return }

    let content = SIMD2(Int(activeW), Int(activeH))
    // Ignore absurd rates rather than time the beam against garbage; 0 = not reported.
    let hz: Float = (refreshHz > 20.0 && refreshHz < 200.0) ? refreshHz : 0.0

    // Re-locking is expensive (rebuilds the layout, scaler and VGA encoder), so only a
    // REAL sync change counts. The CRTC's derived rate jitters in the last decimal
    // (70.086 vs 70.087 on the same mode); a tube would not re-lock over a millihertz.
    let resolutionChanged = content != state.contentSize
    let refreshChanged    = abs(hz - state.signalRefreshHz) > 0.05   // Hz
    guard resolutionChanged || refreshChanged else { return }

    state.signalRefreshHz = hz
    applyPresetInternal(state, preset: preset, phosphor: phosphor, content: content)
}

@_cdecl("crt_bridge_set_display_refresh")
public func crt_bridge_set_display_refresh(_ ref: UnsafeMutableRawPointer,
                                           _ hz: Float) {
    let state = Unmanaged<CRTBridgeState>.fromOpaque(ref).takeUnretainedValue()
    state.filter.displayRefreshRate = hz
}

/// Report the PHYSICAL DISPLAY to the engine: geometry, PPI, EDR headroom, refresh —
/// everything CRTEngine needs to render optimally for this panel. `screenPtr` is an
/// NSScreen* (or NULL for the main screen).
///
/// Call at init AND on every event that changes the display: window moved to another
/// screen, resolution or scaled-mode change, backing-scale change, EDR/HDR change,
/// display connect/disconnect. The host's only job here is to notice and report; the
/// engine decides what to do about it (mask pitch, render resolution, HDR dimming).
///
/// This re-runs the LAYOUT, not just the EDR/brightness compensation: under
/// `.displayOnly` the phosphor pitch is anchored to the panel's physical pixels and
/// the render width is derived from it, so a new panel means a new layout. Updating
/// the environment without re-laying-out would leave the engine rendering a mask
/// sized for the display it is no longer on.
@_cdecl("crt_bridge_update_display")
public func crt_bridge_update_display(_ ref: UnsafeMutableRawPointer,
                                      _ screenPtr: UnsafeMutableRawPointer?) {
    let state = Unmanaged<CRTBridgeState>.fromOpaque(ref).takeUnretainedValue()
    let screen: NSScreen? = screenPtr.map {
        Unmanaged<NSScreen>.fromOpaque($0).takeUnretainedValue()
    }
    state.displayEnv.updateScreen(screen ?? NSScreen.main)
    recomputeLayout(state)          // panel-anchored pitch + render width re-derive
    applyDisplayEnvironment(state)  // EDR boost + stripe compensation (needs the new pattern)
}

/// The display's currently-available EDR headroom (1.0 = SDR, >1 = HDR capable).
/// The host uses this to decide whether to put its CAMetalLayer in EDR mode.
// Returns the panel's POTENTIAL headroom (capability): the host decides the layer
// format from this. Using CURRENT here is the classic EDR chicken-and-egg — current
// reads 1.0 until EDR content is on screen, so the layer never goes EDR and EDR
// never engages. The live CURRENT headroom is what clamps the highlight ceiling,
// re-read per frame in crt_bridge_present.
@_cdecl("crt_bridge_edr_headroom")
public func crt_bridge_edr_headroom(_ ref: UnsafeMutableRawPointer) -> Float {
    let state = Unmanaged<CRTBridgeState>.fromOpaque(ref).takeUnretainedValue()
    return Float(state.displayEnv.edrPotential)
}

/// Set the fixed phosphor render width (px). Higher = finer stripes/mask, more
/// GPU. 0 = render at the window size. Re-lays-out immediately.
@_cdecl("crt_bridge_set_render_resolution")
public func crt_bridge_set_render_resolution(_ ref: UnsafeMutableRawPointer,
                                             _ width: Int32) {
    let state = Unmanaged<CRTBridgeState>.fromOpaque(ref).takeUnretainedValue()
    state.renderWidthOverride = Int(max(0, width))   // 0 = let the engine decide
    recomputeLayout(state)
}

/// `.displayOnly` RGB mask scale (Pattern Scale): a multiplier of the engine's physical
/// phosphor pitch. 1.0 = the tube's real pitch; higher coarsens the grille so it reads at
/// smaller sizes (a fine VGA tube is sub-Nyquist at typical windows and needs several ×).
/// CRTEngine 1.4.0 supports 1–10×; clamped to match.
@_cdecl("crt_bridge_set_mask_scale")
public func crt_bridge_set_mask_scale(_ ref: UnsafeMutableRawPointer, _ scale: Float) {
    let state = Unmanaged<CRTBridgeState>.fromOpaque(ref).takeUnretainedValue()
    state.displayMaskScale = max(1.0, min(10.0, scale))
    recomputeLayout(state)
}

/// Turn HDR (EDR peak-brightness boost) on/off. On → auto (use the display's EDR
/// headroom); off → clamp to SDR. The mask-dim above still governs how the mask
/// reacts while HDR is on.
/// Peak highlights (replaces the old HDR on/off + boost): how far the tube's
/// >1.0 peaks (mask sparkle, small-area highlights) may render above reference
/// white [1.0 … 3.0]. 1.0 = SDR look on every panel. Always capped by the LIVE
/// panel headroom in the engine's highlight shoulder — the picture body (≤0.85×
/// reference) is identity on every panel, so this can never blow out the image.
@_cdecl("crt_bridge_set_peak_highlights")
public func crt_bridge_set_peak_highlights(_ ref: UnsafeMutableRawPointer, _ v: Float) {
    let state = Unmanaged<CRTBridgeState>.fromOpaque(ref).takeUnretainedValue()
    state.filter.parameters.display.peakAllowance = max(1.0, min(16.0, v))
}

// MARK: - C ABI: picture + phosphor pattern + monitor conditions

/// Picture brightness DC offset (≈ -0.4 … +0.5; 0 = neutral).
@_cdecl("crt_bridge_set_brightness")
public func crt_bridge_set_brightness(_ ref: UnsafeMutableRawPointer, _ v: Float) {
    let s = Unmanaged<CRTBridgeState>.fromOpaque(ref).takeUnretainedValue()
    s.brightnessOverride = v
    s.filter.parameters.display.brightness = v
}

/// Picture contrast gain (≈ 0.1 … 3.0; preset default ~1.5).
@_cdecl("crt_bridge_set_contrast")
public func crt_bridge_set_contrast(_ ref: UnsafeMutableRawPointer, _ v: Float) {
    let s = Unmanaged<CRTBridgeState>.fromOpaque(ref).takeUnretainedValue()
    s.contrastOverride = v
    s.filter.parameters.display.contrast = v
}

/// Phosphor pattern override: 0=triode, 1=stripe (aperture grille), 2=shadow
/// mask, 3=slot mask. Re-lays out and refreshes mask/chroma/brightness state.
@_cdecl("crt_bridge_set_phosphor_pattern")
public func crt_bridge_set_phosphor_pattern(_ ref: UnsafeMutableRawPointer, _ pattern: Int32) {
    let state = Unmanaged<CRTBridgeState>.fromOpaque(ref).takeUnretainedValue()
    state.patternOverride = Int(max(0, min(3, pattern)))
    recomputeLayout(state)
    let p = effectivePattern(state)
    state.filter.parameters.display.chromaNotchStrength = (p == 1 || p == 3) ? 1.0 : 0.0
    // (No applyDisplayEnvironment here: refresh/EDR don't depend on pattern, and the old
    // pattern-dependent stripeBrightnessBoost it used to refresh is gone as of 1.4.0.)
}

/// RGB convergence error, bipolar [-10, 10]: 0 = perfectly aligned, sign chooses
/// the fringing direction (guns misconverge left vs right), magnitude = severity.
@_cdecl("crt_bridge_set_convergence")
public func crt_bridge_set_convergence(_ ref: UnsafeMutableRawPointer, _ v: Float) {
    let state = Unmanaged<CRTBridgeState>.fromOpaque(ref).takeUnretainedValue()
    state.convergenceRaw = max(-10.0, min(10.0, v))
    applyConvergence(state)
}

/// Horizontal jitter: per-scanline horizontal shift in pixels (0 … ~3).
@_cdecl("crt_bridge_set_h_jitter")
public func crt_bridge_set_h_jitter(_ ref: UnsafeMutableRawPointer, _ v: Float) {
    let s = Unmanaged<CRTBridgeState>.fromOpaque(ref).takeUnretainedValue()
    s.hJitterOverride = v
    s.filter.parameters.aging.horizontalInstability = v
}

/// Vertical jitter: per-frame vertical bounce in scanlines (0 … ~2).
@_cdecl("crt_bridge_set_v_jitter")
public func crt_bridge_set_v_jitter(_ ref: UnsafeMutableRawPointer, _ v: Float) {
    let s = Unmanaged<CRTBridgeState>.fromOpaque(ref).takeUnretainedValue()
    s.vJitterOverride = v
    s.filter.parameters.aging.verticalInstability = v
}

/// Beam sharpness dial: 0 = soft (beam fills the scanline cell), 1 = sharp
/// (tight Nyquist-limited beam, crisp scanlines). Perceptually linear and
/// resolution-aware. Drives beam width + scanline visibility, so it re-lays-out.
@_cdecl("crt_bridge_set_sharpness")
public func crt_bridge_set_sharpness(_ ref: UnsafeMutableRawPointer, _ s: Float) {
    let state = Unmanaged<CRTBridgeState>.fromOpaque(ref).takeUnretainedValue()
    state.sharpnessOverride = max(0.0, min(1.0, s))
    recomputeLayout(state)
}

/// Edge focus degradation: beam defocus toward the screen edges (0 … 1).
@_cdecl("crt_bridge_set_edge_focus")
public func crt_bridge_set_edge_focus(_ ref: UnsafeMutableRawPointer, _ v: Float) {
    let s = Unmanaged<CRTBridgeState>.fromOpaque(ref).takeUnretainedValue()
    s.edgeFocusOverride = v
    s.filter.parameters.beam.edgeFocusDegradation = v
}

/// Dynamic bloom: beam widening with brightness / space-charge (0 … ~0.5).
@_cdecl("crt_bridge_set_bloom")
public func crt_bridge_set_bloom(_ ref: UnsafeMutableRawPointer, _ v: Float) {
    let s = Unmanaged<CRTBridgeState>.fromOpaque(ref).takeUnretainedValue()
    s.bloomOverride = v
    s.filter.parameters.beam.dynamicBloomStrength = v
}

/// Per-pixel shot noise (0 = off; ~0.03 = subtle grain).
@_cdecl("crt_bridge_set_shot_noise")
public func crt_bridge_set_shot_noise(_ ref: UnsafeMutableRawPointer, _ v: Float) {
    let s = Unmanaged<CRTBridgeState>.fromOpaque(ref).takeUnretainedValue()
    s.shotNoiseOverride = v
    s.filter.parameters.beam.beamShotNoise = v
}

/// Horizontal video bandwidth — the raised-cosine reconstruction rolloff β
/// [0 … 1.0]. Lower = wider flat passband = sharper (but the sinc-derived filter's
/// negative lobes ring more on hard edges); higher = softer rolloff, less ringing.
/// 0 drops to CRTEngine's legacy Gaussian spot (`sampleBeamHSpot`), which is
/// strictly positive — genuinely ringless, a pristine digital-VGA look — at the
/// cost of losing the anti-banding reconstruction's resample-beat protection on
/// modes where the render buffer isn't an integer multiple of the signal. That
/// trade-off is the host's call to make per mode/preset, not a fixed floor.
@_cdecl("crt_bridge_set_h_bandwidth")
public func crt_bridge_set_h_bandwidth(_ ref: UnsafeMutableRawPointer, _ v: Float) {
    let s = Unmanaged<CRTBridgeState>.fromOpaque(ref).takeUnretainedValue()
    let b = max(0.0, min(1.0, v))
    s.hBandwidthOverride = b
    s.filter.parameters.beam.beamHorizontalRolloff = b
}

/// Horizontal optical focus blur σ in source pixels [0 … 2]. 0 = perfectly
/// focused (default); higher = defocused beam. Purely aesthetic — the anti-banding
/// reconstruction above is independent of this.
@_cdecl("crt_bridge_set_h_focus")
public func crt_bridge_set_h_focus(_ ref: UnsafeMutableRawPointer, _ v: Float) {
    let s = Unmanaged<CRTBridgeState>.fromOpaque(ref).takeUnretainedValue()
    // Bipolar focus pot: 0 = focused; both directions defocus, σ = |v|.
    let f = min(3.0, abs(v))
    s.hFocusOverride = f
    s.filter.parameters.beam.beamHorizontalSpot = f
}

/// Beam temporal resolution [0 … 1] — SIMULATION control, not a shader dial.
/// 1 = the whole scanline is excited at one instant (legacy engine, bit-exact,
/// zero flicker). Below 1 the beam becomes a segmented dot covering that
/// fraction of the line: cells get real per-segment excitation times, decay
/// from their own age, and the display integrates emission over the frame
/// (exposure model) — flicker/shimmer emerge physically as the dial approaches
/// a dot. 0 maps to the engine's shortest segment (1/1024 of a line).
@_cdecl("crt_bridge_set_beam_segment")
public func crt_bridge_set_beam_segment(_ ref: UnsafeMutableRawPointer, _ v: Float) {
    let s = Unmanaged<CRTBridgeState>.fromOpaque(ref).takeUnretainedValue()
    // The user dial lives entirely in the new beam simulation: 1.00 = the new
    // physics fully fused, not the legacy engine (exact 1.0 stays an internal
    // identity-harness anchor), so the top maps just below it.
    let f = max(0.0, min(0.9995, v))
    s.beamSegmentOverride = f
    s.filter.parameters.beam.beamSegmentFraction = f
}

/// OBSERVER dial ("Shutter") [0 … 1]: how the viewer integrates the tube's
/// pulsing emission. 1 = fully fused (rested eye — steady); lower = an
/// ever-faster camera shutter — rolling band and flicker, the filmed-CRT look.
@_cdecl("crt_bridge_set_shutter")
public func crt_bridge_set_shutter(_ ref: UnsafeMutableRawPointer, _ v: Float) {
    let s = Unmanaged<CRTBridgeState>.fromOpaque(ref).takeUnretainedValue()
    let f = max(0.0, min(1.0, v))
    s.shutterOverride = f
    s.filter.parameters.display.observerShutter = f
}

/// Scanline smoothing [0 … 1]: fills the scanline gaps when the output can't
/// resolve them (< ~3 px/scanline — small windows, low-res recordings), trading
/// gap depth for freedom from shimmer/aliasing. 0 = sharp gaps everywhere.
@_cdecl("crt_bridge_set_scanline_smoothing")
public func crt_bridge_set_scanline_smoothing(_ ref: UnsafeMutableRawPointer, _ v: Float) {
    let s = Unmanaged<CRTBridgeState>.fromOpaque(ref).takeUnretainedValue()
    let f = max(0.0, min(1.0, v))
    s.scanSmoothOverride = f
    s.filter.parameters.beam.scanlineBandLimit = f
    recomputeLayout(s)   // the sharp half also relaxes the beam-sigma floor (layout-derived)
}

/// Pattern smoothing [0 … 1]: mask anti-alias strength at the chosen Pattern Scale.
/// 1 = full band-limit margin (clean), 0.5 = pre-margin ramp, 0 = raw pattern
/// (maximum grille detail, moiré is the user's choice).
@_cdecl("crt_bridge_set_pattern_smooth")
public func crt_bridge_set_pattern_smooth(_ ref: UnsafeMutableRawPointer, _ v: Float) {
    let s = Unmanaged<CRTBridgeState>.fromOpaque(ref).takeUnretainedValue()
    let f = max(0.0, min(2.0, v))
    s.patternSmoothOverride = f
    s.filter.parameters.display.maskSmoothing = f
}

/// Additive signal noise / snow (0 … ~0.15).
@_cdecl("crt_bridge_set_signal_noise")
public func crt_bridge_set_signal_noise(_ ref: UnsafeMutableRawPointer, _ v: Float) {
    let s = Unmanaged<CRTBridgeState>.fromOpaque(ref).takeUnretainedValue()
    s.signalNoiseOverride = v
    s.filter.parameters.aging.signalNoise = v
}

@_cdecl("crt_bridge_set_drawable_size")
public func crt_bridge_set_drawable_size(_ ref: UnsafeMutableRawPointer,
                                         _ width: Int32,
                                         _ height: Int32) {
    let state = Unmanaged<CRTBridgeState>.fromOpaque(ref).takeUnretainedValue()
    state.drawableSize = CGSize(width: Int(width), height: Int(height))
    recomputeLayout(state)   // render resolution is derived here, from mode + display
}

// MARK: - C ABI: per-frame render

@_cdecl("crt_bridge_render")
public func crt_bridge_render(_ ref: UnsafeMutableRawPointer,
                              _ inputPtr: UnsafeMutableRawPointer,
                              _ time: Float,
                              _ cmdPtr: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
    let state = Unmanaged<CRTBridgeState>.fromOpaque(ref).takeUnretainedValue()
    guard let input = object(inputPtr, as: MTLTexture.self) else {
        NSLog("[CRTBridge] render: inputTexture is not an MTLTexture")
        return nil
    }
    guard let cmd = object(cmdPtr, as: MTLCommandBuffer.self) else {
        NSLog("[CRTBridge] render: commandBuffer is not an MTLCommandBuffer")
        return nil
    }
    guard let out = state.filter.render(inputTexture: input, time: time,
                                        commandBuffer: cmd) else {
        return nil
    }
    // Borrowed: the engine owns/reuses this texture across frames.
    return Unmanaged.passUnretained(out as AnyObject).toOpaque()
}

/// Run the CRT and put it on the host's drawable — the whole display tail, in the engine.
///
/// This replaces "crt_bridge_render() then scale it yourself". The host must NOT hand-roll
/// that last step: the phosphor buffer carries a 1px RGB mask and a scanline comb (content
/// at Nyquist), so it has to be band-limited on the way out at EVERY scale ratio, and the
/// engine's linear >1.0 output has to be encoded to match whatever the drawable actually
/// is. Both are engine policy; see CRTEngine's DisplayCompositor.
///
/// `sdrEncoded` describes the DRAWABLE, and only the host knows it:
///   false → extended-linear float drawable (rgba16Float + extendedLinear*): write linear,
///           let the OS tonemap above-white against the panel's real EDR headroom.
///   true  → 8-bit gamma drawable (bgra8Unorm + DisplayP3/sRGB): soft-clip the above-white
///           peaks and apply the BT.709 OETF. Writing linear here reads DARK.
/// Get this wrong and no brightness/contrast setting can rescue the picture.
///
/// The picture is placed using the ENGINE's viewport (aspect-preserving, pillar/letterboxed),
/// so the host does not compute an aspect fit either.
@_cdecl("crt_bridge_present")
public func crt_bridge_present(_ ref: UnsafeMutableRawPointer,
                               _ inputPtr: UnsafeMutableRawPointer,
                               _ time: Float,
                               _ targetPtr: UnsafeMutableRawPointer,
                               _ cmdPtr: UnsafeMutableRawPointer,
                               _ sdrEncoded: Bool) -> Bool {
    let state = Unmanaged<CRTBridgeState>.fromOpaque(ref).takeUnretainedValue()
    guard let input = object(inputPtr, as: MTLTexture.self),
          let target = object(targetPtr, as: MTLTexture.self),
          let cmd = object(cmdPtr, as: MTLCommandBuffer.self) else {
        NSLog("[CRTBridge] present: bad input/target/commandBuffer")
        return false
    }

    let transfer: PipelineFactory.DisplayTransfer = sdrEncoded ? .sdrEncoded : .linear
    if state.compositor == nil
        || state.compositor?.colorPixelFormat != target.pixelFormat
        || state.compositor?.transfer != transfer {
        do {
            state.compositor = try DisplayCompositor(device: state.device,
                                                     colorPixelFormat: target.pixelFormat,
                                                     transfer: transfer)
        } catch {
            NSLog("[CRTBridge] present: compositor build failed: \(error)")
            return false
        }
    }
    guard let compositor = state.compositor else { return false }

    // Run the phosphor simulation for this frame. Its phosphor-buffer display output is
    // unused — we re-render the display at OUTPUT resolution below (the CRTEngine 1.4.0
    // surface-mask path), so the RGB mask is evaluated at on-screen pixels and stays sharp
    // at any window size instead of being baked into the phosphor buffer and upscaled.
    _ = state.filter.render(inputTexture: input, time: time, commandBuffer: cmd)

    // (Re)allocate the viewport-sized display surface, then render the mask + display tail
    // into it at that resolution.
    let vp = state.scaling.viewport
    let vw = Int(vp.width.rounded()), vh = Int(vp.height.rounded())
    guard vw > 1, vh > 1 else { return false }
    if state.displaySurface == nil
        || state.displaySurface?.width != vw
        || state.displaySurface?.height != vh {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: vw, height: vh, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        state.displaySurface = state.device.makeTexture(descriptor: desc)
        state.displaySurface?.label = "CRTBridge_DisplaySurface"
    }
    // Display-pass highlight ceiling: peaks get the panel's LIVE headroom up to
    // the user's allowance; on an SDR panel this is exactly the SDR curve.
    // Re-read the headroom every frame — it's live state (rises when the system
    // engages EDR for our layer, moves with display brightness).
    state.displayEnv.refreshEDR()
    let ceiling = min(max(1.0, state.filter.parameters.display.peakAllowance),
                      max(1.0, Float(state.displayEnv.edrCurrent)))
    guard let surface = state.displaySurface,
          state.filter.renderDisplay(to: surface, commandBuffer: cmd,
                                     highlightCeiling: ceiling) != nil else {
        return false
    }

    // The compositor now runs 1:1 (surface is already viewport-sized): it just places the
    // picture with the engine's aspect-preserving viewport and applies the drawable's transfer.
    compositor.composite(crtOutput: surface,
                         to: target,
                         viewport: state.scaling.viewport,
                         commandBuffer: cmd)
    return true
}

/// Run the phosphor simulation and render the CRT directly into `targetPtr`
/// (an id<MTLTexture>) at the target's own resolution, using the engine's display
/// shader (its derivative-aware downscale + target-sized mask LOD). The host
/// presents the target 1:1 — no host-side scaling of the phosphor, so no resample
/// artifacts. `target` should be 4:3 to match the CRT. Returns false on failure.
@_cdecl("crt_bridge_render_display")
public func crt_bridge_render_display(_ ref: UnsafeMutableRawPointer,
                                      _ inputPtr: UnsafeMutableRawPointer,
                                      _ time: Float,
                                      _ cmdPtr: UnsafeMutableRawPointer,
                                      _ targetPtr: UnsafeMutableRawPointer) -> Bool {
    let state = Unmanaged<CRTBridgeState>.fromOpaque(ref).takeUnretainedValue()
    guard let input  = object(inputPtr,  as: MTLTexture.self),
          let cmd    = object(cmdPtr,    as: MTLCommandBuffer.self),
          let target = object(targetPtr, as: MTLTexture.self) else {
        NSLog("[CRTBridge] render_display: bad texture/command-buffer pointer")
        return false
    }
    // Run the phosphor sim for this frame (its phosphor-res display output is
    // unused), then render the display shader into the caller's target.
    _ = state.filter.render(inputTexture: input, time: time, commandBuffer: cmd)
    state.filter.renderDisplay(to: target, commandBuffer: cmd)
    return true
}

@_cdecl("crt_bridge_resize")
public func crt_bridge_resize(_ ref: UnsafeMutableRawPointer,
                              _ width: Int32, _ height: Int32) {
    let state = Unmanaged<CRTBridgeState>.fromOpaque(ref).takeUnretainedValue()
    state.filter.resize(width: Int(width), height: Int(height))
}

@_cdecl("crt_bridge_destroy")
public func crt_bridge_destroy(_ ref: UnsafeMutableRawPointer) {
    Unmanaged<CRTBridgeState>.fromOpaque(ref).release()
}
