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
    var drawableSize: CGSize = CGSize(width: 0, height: 0)
    /// Fixed phosphor-buffer render width (px). Decouples stripe fineness from
    /// window size; the result is scaled to the drawable. 0 = use the viewport.
    /// 2880 = Phosphors' 4:3 "4K" default (== MaskLOD.referenceWidth, so the mask
    /// renders cleanly with zero LOD fade).
    var renderResolutionWidth: Int = 2880
    /// `.displayOnly` RGB mask scale — a multiplier of the engine's algorithmic
    /// finest pitch. 1.0 (default) = finest (1px per aperture-grille stripe = 3px
    /// triplet); 2.0/3.0 = coarser (the "1x/2x/3x" render-options control). Set via
    /// crt_bridge_set_mask_scale; the CRT_MASK_SCALE env var seeds it. See CRTEngine
    /// docs/RenderIntent-DisplayVsRecording.md.
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
    /// .displayOnly HDR mask dim strength (0 = off, 1 = strong). Seeded from
    /// CRT_HDR_MASK_DIM; how much EDR headroom fades the mask toward flat to tame the
    /// harsh crosshatch on HDR panels.
    var hdrMaskDim: Float =
        Float(ProcessInfo.processInfo.environment["CRT_HDR_MASK_DIM"] ?? "") ?? 0.5
    let displayEnv = DisplayEnvironment()

    init(device: MTLDevice, filter: CRTFilter, scaling: ScalingManager) {
        self.device = device
        self.filter = filter
        self.scaling = scaling
    }
}

/// Displayed scanline count for the current mode. A multisync monitor tracks the
/// input's vertical resolution, but low-res modes (CGA/VGA 200- and 240-line) are
/// SCAN-DOUBLED on real VGA monitors to ~400/480 displayed lines so the scanline
/// density stays right — without this, a 200-line mode shows 200 sparse scanlines
/// spread over the screen (looks like half vertical resolution). A fixed-frequency
/// monitor uses the preset's value.
private func multisyncScanlines(_ preset: CRTPreset, _ contentH: Int) -> Int {
    guard preset.multiSync else { return preset.scanlineCount }
    var lines = contentH
    while lines < 350 { lines *= 2 }   // 200→400, 240→480; 350/400/480 unchanged
    return max(200, min(lines, 1024))
}

/// Vertical refresh (Hz) the emulated card sends for a given NATIVE mode height.
/// A multisync monitor has no rate of its own — it locks to the signal — so for
/// multisync presets the refresh comes from the mode, not the preset's scalar.
/// Simple standard-VGA/VESA table keyed on native scanline count:
///   ≤400 lines (CGA 200 / EGA 350 / VGA 720×400 text): 70 Hz — the classic
///     "VGA runs text/400-line at 70 Hz" behavior.
///   ≥480 lines (VGA 640×480 and SVGA 600/768/1024…): 60 Hz default.
/// Fixed-frequency presets (TVs) keep their own physical rate (59.94/50).
/// Exact per-mode timing lives in 86Box's CRTC; a future set_signal_refresh()
/// could feed the precise value and supersede this table.
private func signalRefreshHz(_ preset: CRTPreset, _ contentH: Int) -> Float {
    guard preset.multiSync else { return preset.refreshRate }
    return contentH < 480 ? 70.0 : 60.0
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
    state.filter.parameters.display.hdrMaskDim = state.hdrMaskDim
}

/// Push host-display capabilities into the filter: refresh cadence and EDR
/// brightness compensation. Mirrors Phosphors' `updateEDRCompensation` so the
/// stripe/mask patterns aren't left dim on HDR displays.
private func applyDisplayEnvironment(_ state: CRTBridgeState) {
    let env = state.displayEnv
    state.filter.displayRefreshRate = Float(env.info.maxRefreshRate)

    let edrBoost = env.edrMultiplier
    state.filter.parameters.display.edrBoost = edrBoost

    let pattern = state.filter.parameters.phosphor.colorPhosphorPattern
    if pattern >= 1 && pattern <= 3 {
        // Stripe/mask/slot: each pixel lights only 1 of R/G/B → ~3x perceptual
        // compensation, capped by the display's currently-available headroom.
        let idealBoost = edrBoost * EDRCompensation.stripePerceptualCompensation
        let peakSafe = Float(max(1.0, env.edrCurrent)) * EDRCompensation.headroomSafetyFactor
        state.filter.parameters.display.stripeBrightnessBoost =
            max(EDRCompensation.defaultSDRFloor, min(idealBoost, peakSafe))
    } else {
        // Triode: full coverage; edrBoost is applied separately in-shader.
        state.filter.parameters.display.stripeBrightnessBoost = 1.0
    }
}

// MARK: - Internal helpers

private func applyPresetInternal(_ state: CRTBridgeState,
                                 preset: CRTPreset,
                                 phosphor: PhosphorPreset,
                                 content: SIMD2<Int>) {
    state.preset = preset
    state.phosphor = phosphor
    state.contentSize = content

    // Multisync: the scanline structure tracks the input's vertical resolution.
    // CRTEngine is used unmodified, so we apply the preset normally and then set
    // the scanline count directly on the public timing parameters (the VGA
    // encoder keeps the preset's max-output budget, which is fine).
    let scanlines = multisyncScanlines(preset, content.y)
    // Signal refresh tracks the mode for multisync monitors (e.g. 70 Hz for VGA
    // 720×400 text, 60 Hz for 640×480+); fixed-freq tubes keep the preset's rate.
    let refreshHz = signalRefreshHz(preset, content.y)
    state.filter.applyPreset(preset, phosphor: phosphor, contentSize: content)
    state.filter.parameters.timing.scanRate = refreshHz
    state.filter.parameters.timing.crtRefreshRate = refreshHz
    state.filter.parameters.timing.interlaced = preset.interlaced
    state.filter.parameters.timing.scanlineCount = Int32(scanlines)

    // The beam paints `vgaEncoder.scanlineCount` scanlines (CRTFilter sets
    // crtUniforms.scanlineCount = vga.scanlineCount), and applyPreset configured the
    // encoder to the preset's MAX-output budget (e.g. 600). For a MULTISYNC monitor
    // the displayed line count must track the input instead (480 for a 640x480
    // mode) — otherwise the beam paints far more scanlines than the window can
    // resolve and they beat into uneven "bunches and gaps". Re-point the encoder's
    // output at the multisync count; its output then matches the native content, so
    // the encode pass runs 1:1 (passthrough) — no horizontal resample.
    if state.filter.isVGAPipeline {
        state.filter.vgaEncoder?.configureMaxOutput(scanlineCount: scanlines,
                                                     refreshRate: refreshHz,
                                                     aspectRatio: 4.0 / 3.0)
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

private func recomputeLayout(_ state: CRTBridgeState) {
    guard let preset = state.preset,
          state.drawableSize.width > 0, state.drawableSize.height > 0 else { return }
    _ = state.scaling.updateDrawableSize(state.drawableSize)
    let scanlines = multisyncScanlines(preset, Int(state.contentSize.y))

    // Render resolution is an ENGINE decision now (D2): the bridge reports the
    // display fact — the CRT-content width in backing pixels — and CRTEngine's
    // policy decides the render width. (Rationale for rendering at ~display width
    // rather than oversampling lives in ScalingManager.autoDisplayRenderWidth /
    // docs/RenderIntent-DisplayVsRecording.md.) We hold the chosen width locally too,
    // for the sharpness→beamFalloff mapping and maskLODBias below; it comes from the
    // same policy, so there is one source of truth and no divergence.
    let dispW = min(Float(state.drawableSize.width),
                    Float(state.drawableSize.height) * 4.0 / 3.0)
    state.renderResolutionWidth = ScalingManager.autoDisplayRenderWidth(contentWidth: Int(dispW))

    // Physical panel fact for the engine's panel-anchored pitch: native panel px per
    // framebuffer(backing) px. 1.0 in native display mode; < 1 in a scaled desktop
    // mode where the OS resamples the framebuffer down onto the panel. Falls back to
    // 1.0 until the display env is known.
    let info = state.displayEnv.info
    let framebufferW = Float(info.logicalSize.width) * Float(info.backingScaleFactor)
    let panelNativeW = Float(info.nativePixelWidth)
    let panelScale: Float = (framebufferW > 1 && panelNativeW > 1) ? (panelNativeW / framebufferW) : 1.0
    let pxPerScanline = max(2, Int((Float(state.renderResolutionWidth) * 3.0 / 4.0)
                                    / Float(max(1, scanlines))))

    // Beam falloff: from the perceptually-linear sharpness dial if the user set
    // it, else the preset's value. The dial maps to a Gaussian σ anchored to the
    // scanline cell, so the full slider travel is useful at any resolution (raw
    // beamFalloff is wildly non-linear — all the visible change is in ~0.7…0.9).
    let beamFalloff: Float
    if let s = state.sharpnessOverride {
        let spacing = Float(pxPerScanline)
        let sigma = BeamSharpness.sigma(forSharpness: s, scanlineSpacing: spacing)
        beamFalloff = BeamSharpness.falloff(forSigma: sigma, scanlineSpacing: spacing)
    } else {
        beamFalloff = preset.beamFalloff
    }

    let inputs = CRTLayoutInputs(
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
        // Render the phosphor buffer at the display resolution and present 1:1.
        renderResolutionWidth: state.renderResolutionWidth,
        // minStripePixels now unused on the .displayOnly path (the engine uses the
        // panel-anchored displayStripePixels instead); kept 2.0 as a safe fallback.
        minStripePixels: 2.0,
        // 86Box presents 1:1 to a physical panel and never records — display-only.
        renderIntent: .displayOnly,
        // Report the physical panel facts; the engine decides the pitch. backing→
        // panel scale = native panel px per framebuffer(backing) px (1.0 native;
        // <1 in a scaled "More Space" desktop where the OS resamples to the panel).
        backingToPanelScale: panelScale,
        // RGB mask scale (1x/2x/3x) — multiplier of the engine's algorithmic finest.
        displayMaskScale: state.displayMaskScale
    )
    let layout = state.scaling.computeLayout(inputs)
    state.scaling.applyLayoutState(layout)
    state.filter.apply(layout)

    // Mask/stripe LOD fade — now that we render at the display resolution,
    // renderResolutionWidth IS the resolution the mask is viewed at, so the engine's
    // stock LOD policy applies directly (extra fade below its 2880 reference; none
    // above). No oversample means no phosphor→window downscale to defeat it.
    state.filter.maskLODBias = MaskLOD.bias(forRenderWidth: state.renderResolutionWidth)

    // Re-apply convergence — pixelScale may have changed with the render res, and
    // apply(layout) can reset beam params. Keeps the user's setting consistent.
    applyConvergence(state)
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
@_cdecl("crt_bridge_set_content_size")
public func crt_bridge_set_content_size(_ ref: UnsafeMutableRawPointer,
                                        _ contentW: Int32,
                                        _ contentH: Int32) {
    let state = Unmanaged<CRTBridgeState>.fromOpaque(ref).takeUnretainedValue()
    guard let preset = state.preset, let phosphor = state.phosphor else { return }
    applyPresetInternal(state, preset: preset, phosphor: phosphor,
                        content: SIMD2(Int(contentW), Int(contentH)))
}

@_cdecl("crt_bridge_set_display_refresh")
public func crt_bridge_set_display_refresh(_ ref: UnsafeMutableRawPointer,
                                           _ hz: Float) {
    let state = Unmanaged<CRTBridgeState>.fromOpaque(ref).takeUnretainedValue()
    state.filter.displayRefreshRate = hz
}

/// Detect the host display's capabilities (EDR headroom, refresh, scale) from an
/// NSScreen and push them into the filter. `screenPtr` is an NSScreen* (or NULL
/// to use the main screen). Call at init and whenever the window changes screen.
@_cdecl("crt_bridge_update_display")
public func crt_bridge_update_display(_ ref: UnsafeMutableRawPointer,
                                      _ screenPtr: UnsafeMutableRawPointer?) {
    let state = Unmanaged<CRTBridgeState>.fromOpaque(ref).takeUnretainedValue()
    let screen: NSScreen? = screenPtr.map {
        Unmanaged<NSScreen>.fromOpaque($0).takeUnretainedValue()
    }
    state.displayEnv.updateScreen(screen ?? NSScreen.main)
    applyDisplayEnvironment(state)
}

/// The display's currently-available EDR headroom (1.0 = SDR, >1 = HDR capable).
/// The host uses this to decide whether to put its CAMetalLayer in EDR mode.
@_cdecl("crt_bridge_edr_headroom")
public func crt_bridge_edr_headroom(_ ref: UnsafeMutableRawPointer) -> Float {
    let state = Unmanaged<CRTBridgeState>.fromOpaque(ref).takeUnretainedValue()
    return Float(state.displayEnv.edrCurrent)
}

/// Set the fixed phosphor render width (px). Higher = finer stripes/mask, more
/// GPU. 0 = render at the window size. Re-lays-out immediately.
@_cdecl("crt_bridge_set_render_resolution")
public func crt_bridge_set_render_resolution(_ ref: UnsafeMutableRawPointer,
                                             _ width: Int32) {
    let state = Unmanaged<CRTBridgeState>.fromOpaque(ref).takeUnretainedValue()
    state.renderResolutionWidth = Int(max(0, width))
    recomputeLayout(state)
}

/// `.displayOnly` RGB mask scale: a multiplier of the engine's algorithmic finest
/// pitch. 1.0 = finest (1px aperture-grille stripe / 3px triplet); 2.0 / 3.0 =
/// coarser. The "1x/2x/3x" render-options control. Clamped [1, 3].
@_cdecl("crt_bridge_set_mask_scale")
public func crt_bridge_set_mask_scale(_ ref: UnsafeMutableRawPointer, _ scale: Float) {
    let state = Unmanaged<CRTBridgeState>.fromOpaque(ref).takeUnretainedValue()
    state.displayMaskScale = max(1.0, min(3.0, scale))
    recomputeLayout(state)
}

/// HDR mask softening (0 = off … 1 = strong): how much the mask fades toward flat as
/// EDR headroom rises, taming the harsh high-contrast crosshatch on HDR panels.
/// `.displayOnly` only; no effect on SDR displays (edrBoost ~1).
@_cdecl("crt_bridge_set_hdr_mask_dim")
public func crt_bridge_set_hdr_mask_dim(_ ref: UnsafeMutableRawPointer, _ amount: Float) {
    let state = Unmanaged<CRTBridgeState>.fromOpaque(ref).takeUnretainedValue()
    state.hdrMaskDim = max(0.0, min(1.0, amount))
    state.filter.parameters.display.hdrMaskDim = state.hdrMaskDim   // display param — takes next frame
}

/// Turn HDR (EDR peak-brightness boost) on/off. On → auto (use the display's EDR
/// headroom); off → clamp to SDR. The mask-dim above still governs how the mask
/// reacts while HDR is on.
@_cdecl("crt_bridge_set_hdr_enabled")
public func crt_bridge_set_hdr_enabled(_ ref: UnsafeMutableRawPointer, _ enabled: Bool) {
    let state = Unmanaged<CRTBridgeState>.fromOpaque(ref).takeUnretainedValue()
    state.displayEnv.edrMode = enabled ? .auto : .off
    applyDisplayEnvironment(state)
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
    applyDisplayEnvironment(state)   // stripeBrightnessBoost depends on pattern
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
