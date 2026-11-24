//
//  CRTBridge.swift — flat C ABI over CRTEngine.
//
//  Exposes the surface an emulator frontend (the 86Box Qt Metal renderer) needs:
//  create the tube, pick a preset, report the signal and the display, turn the
//  dials, and present a frame. Every entry point is an @_cdecl symbol matching
//  crt_bridge.h, so a clang/Obj-C++ translation unit can drive the
//  (compiled-Swift) engine with no Swift toolchain on the calling side.
//
//  THE SHAPE OF THIS FILE (ported 2026-11-24 to the engine's one-call
//  configuration, CRTEngine docs/HostContract.md §3 and §6):
//
//    • ONE DECLARATION. Everything structural — preset, signal, pattern,
//      Sharpness, drawable — is gathered into a `CRTConfigurationRequest` in
//      `makeRequest` and handed to `CRTFilter.configure(_:)` from `reconfigure`.
//      The engine computes the layout, sizes the buffers and the VGA encoder
//      from it and restarts the beam cadence. Nothing here computes a layout,
//      keeps a ScalingManager or sizes an encoder any more: the bridge used to
//      do all three on the engine's legacy two-step path, with the line count
//      written twice.
//
//    • ONE DIAL TABLE. Every continuous user control is a `Dial`: the range
//      (the engine's own wherever it publishes one), where the preset starts
//      it, and the parameter it writes. The host reads all three through the
//      ABI, so its sliders cannot disagree with the engine about a range or a
//      default, and adding a dial is one case here plus one row in the dialog.
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

@inline(__always)
private func bridgeState(_ ref: UnsafeMutableRawPointer) -> CRTBridgeState {
    Unmanaged<CRTBridgeState>.fromOpaque(ref).takeUnretainedValue()
}

@inline(__always)
private func clamp(_ v: Float, _ r: ClosedRange<Float>) -> Float {
    max(r.lowerBound, min(r.upperBound, v))
}

// MARK: - Presets (the engine's list, loaded once)

/// The engine's bundled presets. The host enumerates THIS rather than keeping its
/// own table of names: its table went stale the day the engine renamed
/// "White CRT monitor" to "B&W CRT monitor", and the dialog kept offering a preset
/// that no longer existed.
private enum PresetLibrary {
    static let loaded: (phosphors: [PhosphorPreset], crts: [CRTPreset])? = PresetLoader.loadPresets()
    static var crts: [CRTPreset] { loaded?.crts ?? [] }
    /// C strings for crt_bridge_preset_name — allocated once, never freed, so the
    /// pointers handed to the host stay valid for the life of the process.
    static let cNames: [UnsafeMutablePointer<CChar>?] = crts.map { strdup($0.name) }

    static func find(_ name: String) -> (preset: CRTPreset, phosphor: PhosphorPreset)? {
        guard let lib = loaded,
              let preset = lib.crts.first(where: { $0.name == name }),
              lib.phosphors.indices.contains(preset.phosphorIndex) else { return nil }
        return (preset, lib.phosphors[preset.phosphorIndex])
    }
}

// MARK: - Dials

/// The continuous user controls. Raw values are the C ABI's `CRTDial` — the two
/// lists MUST stay in step (the host checks crt_bridge_dial_count() against
/// CRT_DIAL_COUNT at bring-up and says so on stderr if they have drifted).
private enum Dial: Int32, CaseIterable {
    case brightness = 0, contrast, saturation, peakHighlights
    case patternScale, patternFocus
    case curvature, halation, scatter, overscan, vignette
    case sharpness, hBandwidth, hFocus, shutter, edgeFocus, bloom, convergence
    case hJitter, vJitter, shotNoise, signalNoise

    /// The dial's travel. Where the engine publishes a range it is read from the
    /// engine (HostContract: "the host's slider reads it") — pattern scale, glass
    /// curvature and scatter, overscan. The rest are the ranges the engine documents
    /// beside each parameter in CRTFilter.swift.
    var range: ClosedRange<Float> {
        switch self {
        case .brightness:     return -0.4...0.5
        case .contrast:       return 0.1...3.0
        case .saturation:     return 0.0...2.0
        // How far the peaks MAY rise; the engine caps it by the panel's live headroom.
        case .peakHighlights: return 1.0...8.0
        case .patternScale:   return ScalingManager.patternScaleRange
        case .patternFocus:   return 0.0...1.0
        case .curvature:      return DisplayParameters.curvatureRange
        case .halation:       return 0.0...1.0
        case .scatter:        return DisplayParameters.scatterRange
        case .overscan:       return BroadcastParameters.overscanRange
        case .vignette:       return 0.0...0.5
        case .sharpness:      return 0.0...1.0
        case .hBandwidth:     return 0.0...1.0
        case .hFocus:         return -3.0...3.0
        case .shutter:        return 0.0...1.0
        case .edgeFocus:      return 0.0...1.0
        case .bloom:          return 0.0...0.5
        case .convergence:    return -10.0...10.0
        case .hJitter:        return 0.0...3.0
        case .vJitter:        return 0.0...2.0
        case .shotNoise:      return 0.0...0.05
        case .signalNoise:    return 0.0...0.15
        }
    }

    /// Where the dial sits when the user has not touched it: the preset's own value
    /// for what a preset carries, the engine's default for everything else.
    /// `d` is the engine's parameters as a fresh filter holds them, captured before
    /// anything was configured (`CRTBridgeState.engineDefaults`) — read, not restated.
    /// (Sharpness has no real entry here — its preset position depends on the layout's
    /// scanline spacing; see `presetSharpness`.)
    func presetValue(_ preset: CRTPreset, engineDefaults d: CRTParameters) -> Float {
        switch self {
        case .brightness:     return preset.brightness
        case .contrast:       return preset.contrast
        case .saturation:     return preset.saturation
        case .peakHighlights: return d.display.peakAllowance
        case .patternScale:   return d.phosphor.patternScale
        case .patternFocus:   return d.phosphor.patternFocus
        case .curvature:      return preset.faceplate.curvature
        case .halation:       return preset.faceplate.halation
        case .scatter:        return preset.faceplate.scatter
        case .overscan:       return CRTFilter.defaultOverscan(for: preset)
        case .vignette:       return preset.vignetteStrength
        case .sharpness:      return 0.5
        case .hBandwidth:     return d.beam.beamHorizontalRolloff
        case .hFocus:         return d.beam.beamHorizontalSpot
        case .shutter:        return d.display.observerShutter
        case .edgeFocus:      return d.beam.edgeFocusDegradation
        case .bloom:          return preset.dynamicBloomStrength
        case .convergence:    return 0.0   // perfectly converged; the user dials in the error
        case .hJitter:        return d.aging.horizontalInstability
        case .vJitter:        return d.aging.verticalInstability
        case .shotNoise:      return preset.beamShotNoise
        case .signalNoise:    return d.aging.signalNoise
        }
    }

    /// Write the dial into the engine's parameters. `pixelScale` is the engine's
    /// own multiplier for quantities stated in reference pixels (CRTFilter.pixelScale):
    /// convergence and horizontal jitter keep their visual size across render
    /// resolutions, exactly as Phosphors pushes them.
    func write(_ v: Float, into p: inout CRTParameters, pixelScale: Float) {
        switch self {
        case .brightness:     p.display.brightness = v
        case .contrast:       p.display.contrast = v
        case .saturation:     p.display.saturation = v
        case .peakHighlights: p.display.peakAllowance = v
        // Triad size in OUTPUT pixels (the engine resolves it per surface). Below
        // about one pixel per stripe the mask integrates to flat — Triode-level.
        case .patternScale:   p.phosphor.patternScale = v
        // Declared intent only: the engine derives spill, dot sigma and depth per
        // pattern (HostContract §3.2).
        case .patternFocus:   p.phosphor.patternFocus = v
        case .curvature:      p.display.faceplateCurvature = v
        case .halation:       p.display.faceplateHalation = v
        case .scatter:        p.display.faceplateScatter = v
        case .overscan:       p.broadcast.overscan = v
        case .vignette:       p.display.vignetteStrength = v
        // Structural: Sharpness is CRTConfigurationRequest.beamFalloff, not a
        // parameter write — the engine derives the beam width and applies its
        // display-domain floor in the layout. See `reconfigure`.
        case .sharpness:      break
        case .hBandwidth:     p.beam.beamHorizontalRolloff = v
        // Bipolar focus pot: 0 = focused; either direction defocuses, σ = |v|.
        case .hFocus:         p.beam.beamHorizontalSpot = abs(v)
        case .shutter:        p.display.observerShutter = v
        case .edgeFocus:      p.beam.edgeFocusDegradation = v
        case .bloom:          p.beam.dynamicBloomStrength = v
        case .convergence:    p.beam.beamConvergence = v * pixelScale
        case .hJitter:        p.aging.horizontalInstability = v * pixelScale
        case .vJitter:        p.aging.verticalInstability = v
        case .shotNoise:      p.beam.beamShotNoise = v
        case .signalNoise:    p.aging.signalNoise = v
        }
    }
}

// MARK: - Bridge state

/// One live engine, plus the host's complete declaration of what it wants from it.
private final class CRTBridgeState {
    let device: MTLDevice
    let filter: CRTFilter
    let displayEnv = DisplayEnvironment()
    /// The engine's parameters before this host touched any of them: where a dial that
    /// no preset carries (video bandwidth, edge focus, pattern focus…) rests.
    let engineDefaults: CRTParameters

    // ---- What the tube is ----
    var preset: CRTPreset?
    var phosphor: PhosphorPreset?

    // ---- The signal on the wire (crt_bridge_set_signal) ----
    var contentSize: SIMD2<Int> = SIMD2(640, 480)
    /// Vertical refresh of the SIGNAL the emulated card is sending, from its CRTC.
    /// This is what the tube locks to — NOT the host panel's refresh (that is
    /// `displayRefreshHz`). 0 = the card did not report it; the preset's rate stands in.
    var signalRefreshHz: Float = 0
    /// The tube refresh last written to the engine, to restart the beam cadence when
    /// only the rate changed (same resolution, 60 → 72 Hz).
    var appliedRefreshHz: Float = 0

    // ---- The display (crt_bridge_set_drawable_size / update_display) ----
    var drawableSize: CGSize
    var displayRefreshHz: Float = 60

    // ---- What the user chose ----
    /// Dial overrides by `Dial.rawValue`. Absent = the preset's position.
    var overrides: [Int32: Float] = [:]
    /// Phosphor pattern override (0 triode … 3 slot). nil = the preset's.
    var patternOverride: Int32? = nil
    /// The beamFalloff last sent for the Sharpness dial, so a reconfigure starts
    /// from the right beam instead of flashing the preset's for one layout.
    var appliedFalloff: Float? = nil
    /// The last layout line written to the signal log, so an unchanged layout is
    /// logged once rather than once per reconfigure.
    var lastLayoutLog: String = ""

    // ---- What the engine decided ----
    var layout: CRTScreenLayout?

    /// The engine's display tail for an 8-bit drawable (band-limited place + SDR
    /// encode). Rebuilt when the drawable's pixel format or transfer changes.
    var compositor: DisplayCompositor? = nil
    /// Viewport-sized float surface the display pass renders into on the 8-bit path.
    /// The float (EDR) path draws straight into the drawable and needs none.
    var displaySurface: MTLTexture? = nil

    init(device: MTLDevice, filter: CRTFilter, drawableSize: CGSize) {
        self.device = device
        self.filter = filter
        self.engineDefaults = filter.parameters
        self.drawableSize = drawableSize
        let hz = Float(displayEnv.info.maxRefreshRate)
        if hz > 0 { displayRefreshHz = hz }
    }

    func value(_ dial: Dial) -> Float {
        if let v = overrides[dial.rawValue] { return v }
        return presetValue(dial)
    }

    /// Where the live preset starts a dial — what a reset returns to.
    func presetValue(_ dial: Dial) -> Float {
        if dial == .sharpness { return presetSharpness }
        return preset.map { dial.presetValue($0, engineDefaults: engineDefaults) }
            ?? dial.range.lowerBound
    }

    /// Where the preset's own beam sits on the Sharpness dial at the current layout.
    /// The dial is anchored to the scanline cell, so the same beamFalloff reads as a
    /// different position at a different scanline spacing — that spacing is the
    /// ENGINE's number, read off the layout it chose.
    var presetSharpness: Float {
        guard let preset = preset, let layout = layout else { return 0.5 }
        let spacing = max(2.0, layout.pixelsPerScanline)
        let sigma = BeamSharpness.beamWidth(forFalloff: preset.beamFalloff, scanlineSpacing: spacing)
        return BeamSharpness.sharpness(forSigma: sigma, scanlineSpacing: spacing)
    }
}

// MARK: - The signal

/// Vertical refresh (Hz) the tube runs at.
///
/// A multisync monitor has no rate of its own — it LOCKS TO THE SIGNAL — so the rate
/// comes from the card, never from the preset. 86Box reports its real CRTC-derived
/// refresh via crt_bridge_set_signal (mon_signal_refresh_hz), and that always wins:
/// a card does not guess its own timing, it *is* the timing.
///
/// When the card DOESN'T report (CGA/MDA/EGA keep their timings in their own structs and
/// are not wired up yet), fall back to the PRESET's refresh — a real number the user
/// chose beats an invented one. Fixed-frequency presets (TVs) keep their own physical
/// rate.
private func tubeRefreshHz(_ state: CRTBridgeState, _ preset: CRTPreset) -> Float {
    guard preset.multiSync else { return preset.refreshRate }
    return state.signalRefreshHz > 0 ? state.signalRefreshHz : preset.refreshRate
}

// MARK: - The declaration

/// The complete configuration this host wants, as intent. Everything here is a SIGNAL
/// fact (resolution, line count), a DISPLAY fact (drawable, refresh) or a USER choice
/// (preset, pattern, Sharpness). Nothing here is a rendering decision — the layout,
/// the buffer, the beam and the encoder are the engine's.
private func makeRequest(_ state: CRTBridgeState,
                         _ preset: CRTPreset,
                         _ phosphor: PhosphorPreset) -> CRTConfigurationRequest {
    var r = CRTConfigurationRequest(
        preset: preset,
        phosphor: phosphor,
        contentSize: state.contentSize,
        drawableSize: state.drawableSize,
        displayRefreshRate: state.displayRefreshHz,
        // 86Box presents 1:1 to a physical panel and never records.
        renderIntent: .displayOnly)

    if preset.multiSync {
        // A multisync monitor paints exactly the raster it is sent, so the lines to
        // scan are the signal's own count.
        //
        // This does NOT scan-double. Scan-doubling is the VIDEO CARD's job: a VGA card
        // running a 200-line mode re-times it to 400 lines (CRTC `crtc[9]` bit 7)
        // before it reaches the cable, and 86Box models that (`svga->linedbl`), so the
        // raster arriving here is already doubled. A genuinely 200-line signal (a real
        // CGA card) is painted as 200 lines — which is what a CGA monitor did.
        let lines = max(1, min(state.contentSize.y, 2048))   // sanity bounds only
        r.scanlineCount = lines
        // The card KNOWS its mode, so the encode runs 1:1 at the signal's real pixel
        // size. Left to derive it (lines × 4/3) the engine is right for the 4:3
        // graphics modes by coincidence and wrong for text: DOS text is 720×400, and
        // 400 × 4/3 = 533 — a quarter of the horizontal detail resampled away before
        // the beam ever saw it. The non-square aspect is resolved where a real monitor
        // resolves it: when the beam paints the signal across the 4:3 glass.
        r.signalResolution = SIMD2(max(1, state.contentSize.x), lines)
    }
    // A fixed-frequency tube (a TV) has one raster it can paint: nil = the preset's
    // lines, and the engine derives the encode from them.

    r.colorPhosphorPattern = state.patternOverride            // nil = the preset's
    r.beamFalloff = state.overrides[Dial.sharpness.rawValue] != nil ? state.appliedFalloff : nil
    return r
}

/// Hand the current declaration to the engine, then write the things the request does
/// not carry: the signal's true refresh, and the dials.
///
/// Safe to call whenever anything structural moved — `configure(_:)` diffs the request
/// and changes only what the change implies.
private func reconfigure(_ state: CRTBridgeState) {
    guard let preset = state.preset, let phosphor = state.phosphor,
          state.drawableSize.width > 0, state.drawableSize.height > 0 else { return }

    var request = makeRequest(state, preset, phosphor)
    let first = state.filter.configure(request)
    var layout = first.layout
    var cadenceReset = first.cadenceReset

    // Sharpness. The dial is perceptually linear over a Gaussian σ anchored to the
    // SCANLINE CELL, so mapping it to beamFalloff needs the scanline spacing — the
    // engine's number. Ask for a layout, read the spacing off it, and re-declare only
    // if the falloff that spacing implies differs from the one just sent (it does not
    // on an ordinary relayout, so this is normally one call).
    if let s = state.overrides[Dial.sharpness.rawValue] {
        let spacing = max(2.0, layout.pixelsPerScanline)
        let sigma = BeamSharpness.sigma(forSharpness: s, scanlineSpacing: spacing)
        let falloff = BeamSharpness.falloff(forSigma: sigma, scanlineSpacing: spacing)
        if request.beamFalloff == nil || abs(falloff - (request.beamFalloff ?? 0)) > 1e-5 {
            request.beamFalloff = falloff
            let second = state.filter.configure(request)
            layout = second.layout
            cadenceReset = cadenceReset || second.cadenceReset
        }
        state.appliedFalloff = falloff
    } else {
        state.appliedFalloff = nil
    }
    state.layout = layout

    // ---- What the request does not carry ----
    var p = state.filter.parameters

    // THE SIGNAL'S REFRESH. `CRTConfigurationRequest` has no field for it: the engine
    // writes the PRESET's refresh, and only when the preset changes. A multisync tube
    // locks to the card, so the card's rate is written here, after every configure.
    // (One writer in practice — the engine's write happens once per preset — but it is
    // a signal fact that belongs in the request; raised with the engine, not patched.)
    let hz = tubeRefreshHz(state, preset)
    p.timing.scanRate = hz
    p.timing.crtRefreshRate = hz
    // The source's content rate is a signal fact too (HostContract §3): 86Box feeds
    // frames and lets the engine pace them, so it declares the card's measured rate,
    // or 0 when the card does not report one. Only the NTSC pipeline acts on it.
    p.timing.hostContentFrameRate = state.signalRefreshHz
    p.timing.hostContentResolution = SIMD2(Int32(state.contentSize.x), Int32(state.contentSize.y))
    // The beam is the dot — its physical truth, pinned, as in Phosphors. Steadiness is
    // the observer's (the Shutter dial).
    p.beam.beamSegmentFraction = 0.0

    let scale = state.filter.pixelScale
    for dial in Dial.allCases {
        dial.write(state.value(dial), into: &p, pixelScale: scale)
    }
    state.filter.parameters = p   // one assignment, one uniform update

    // A rate-only change (640×480 at 60 → 72 Hz) is not in the engine's structural
    // key — that carries the preset's rate — so restart the cadence for it here.
    if abs(hz - state.appliedRefreshHz) > 0.05 {
        if !cadenceReset { state.filter.resetFrameCounter() }
        state.appliedRefreshHz = hz
    }

    state.filter.displayHeadroom = Float(state.displayEnv.edrCurrent)
    logLayout(state, layout)
}

/// Push one dial without a relayout (everything except Sharpness).
private func applyDial(_ state: CRTBridgeState, _ dial: Dial) {
    if dial == .sharpness {
        reconfigure(state)
        return
    }
    var p = state.filter.parameters
    dial.write(state.value(dial), into: &p, pixelScale: state.filter.pixelScale)
    state.filter.parameters = p
}

/// DIAGNOSTIC: record the layout the engine actually chose.
///
/// The signal and display lines in the same file say what went IN; this says what the
/// engine DECIDED — the phosphor buffer, the buffer→viewport ratio, and above all the
/// scanline pitch as it lands ON THE GLASS. They are not guessable from a screenshot: a
/// screenshot is resampled on the way to being viewed, which manufactures exactly the
/// kind of beat one is usually chasing. (A Finder-launched .app has nowhere to put
/// stderr, hence the file.)
private func logLayout(_ state: CRTBridgeState, _ l: CRTScreenLayout) {
    let vpH = Float(l.viewport.height)
    let vpW = Float(l.viewport.width)
    // THE number: scanline pitch on the panel. The phosphor buffer cancels out of it.
    let displayedPitch = vpH / Float(max(1, l.scanlineCount))
    // Buffer→viewport ratio. 1.0 = no resample; anything else resamples the comb.
    let ratio = vpH / Float(max(1, l.phosphorHeight))

    let line = String(
        format: "layout -> signal %dx%d%@ @ %.3f Hz | drawable %.0fx%.0f | viewport %.0fx%.0f"
              + " | buffer %dx%d (k=%.3f) | displayedPitch %.4f px/scanline"
              + " | buf->vp %.5f | renderW %d | beamW %.3f vis %.3f | pattern %d\n",
        state.contentSize.x, l.scanlineCount, l.interlaced ? " INTERLACED" : "",
        state.filter.parameters.timing.crtRefreshRate,
        Float(state.drawableSize.width), Float(state.drawableSize.height),
        vpW, vpH,
        l.phosphorWidth, l.phosphorHeight,
        Float(l.phosphorHeight) / Float(max(1, l.scanlineCount)),
        displayedPitch, ratio, l.renderWidth,
        l.beamWidth, l.scanlineVisibility, l.colorPhosphorPattern)
    guard line != state.lastLayoutLog else { return }   // a decision is logged once
    state.lastLayoutLog = line

    guard let home = ProcessInfo.processInfo.environment["HOME"],
          let f = FileHandle(forWritingAtPath: home + "/Library/Logs/86Box-crt-signal.log")
    else { return }
    defer { try? f.close() }
    f.seekToEndOfFile()
    f.write(Data(line.utf8))
}

// MARK: - C ABI: creation

@_cdecl("crt_bridge_create")
public func crt_bridge_create(_ devicePtr: UnsafeMutableRawPointer,
                              _ drawableW: Int32,
                              _ drawableH: Int32) -> UnsafeMutableRawPointer? {
    guard let device = object(devicePtr, as: MTLDevice.self) else {
        NSLog("[CRTBridge] create: not an MTLDevice")
        return nil
    }
    let w = max(1, Int(drawableW)), h = max(1, Int(drawableH))
    // The initial buffer size is a placeholder: the first configure sizes it properly.
    guard let filter = CRTFilter(device: device, width: w, height: h) else {
        NSLog("[CRTBridge] create: CRTFilter init failed (shader bundle/metallib?)")
        return nil
    }
    let state = CRTBridgeState(device: device, filter: filter,
                               drawableSize: CGSize(width: w, height: h))
    return Unmanaged.passRetained(state).toOpaque()
}

@_cdecl("crt_bridge_destroy")
public func crt_bridge_destroy(_ ref: UnsafeMutableRawPointer) {
    Unmanaged<CRTBridgeState>.fromOpaque(ref).release()
}

// MARK: - C ABI: presets

@_cdecl("crt_bridge_preset_count")
public func crt_bridge_preset_count() -> Int32 {
    Int32(PresetLibrary.crts.count)
}

@_cdecl("crt_bridge_preset_name")
public func crt_bridge_preset_name(_ index: Int32) -> UnsafePointer<CChar>? {
    guard PresetLibrary.cNames.indices.contains(Int(index)),
          let p = PresetLibrary.cNames[Int(index)] else { return nil }
    return UnsafePointer(p)
}

/// Index of the live preset in the engine's list, or -1 before one is set.
@_cdecl("crt_bridge_current_preset")
public func crt_bridge_current_preset(_ ref: UnsafeMutableRawPointer) -> Int32 {
    let state = bridgeState(ref)
    guard let name = state.preset?.name,
          let i = PresetLibrary.crts.firstIndex(where: { $0.name == name }) else { return -1 }
    return Int32(i)
}

/// Switch the tube. The user's dial overrides are kept and re-applied over the new
/// preset's starting positions. Returns false if the name is unknown.
@_cdecl("crt_bridge_set_preset")
public func crt_bridge_set_preset(_ ref: UnsafeMutableRawPointer,
                                  _ namePtr: UnsafePointer<CChar>) -> Bool {
    let state = bridgeState(ref)
    let name = String(cString: namePtr)
    guard let found = PresetLibrary.find(name) else {
        NSLog("[CRTBridge] set_preset: preset '%@' not found", name)
        return false
    }
    state.preset = found.preset
    state.phosphor = found.phosphor
    reconfigure(state)
    return true
}

/// True when the live tube is a colour tube (it has a phosphor pattern to choose).
@_cdecl("crt_bridge_is_color")
public func crt_bridge_is_color(_ ref: UnsafeMutableRawPointer) -> Bool {
    bridgeState(ref).filter.parameters.phosphor.phosphorMode == 1
}

// MARK: - C ABI: the signal and the display

/// THE SIGNAL ON THE WIRE — one atomic description of what the emulated card is
/// sending: active resolution and the card's true vertical refresh (from its CRTC).
///
/// This is the whole cable. It is one-way, exactly like VGA: the card pushes, the
/// tube reacts. Nothing is reported back, because a monitor has no way to talk to a
/// video card. The bridge's job is only to be an HONEST card — real timings, no
/// invention — and CRTEngine's job is to respond correctly to whatever arrives.
///
/// Resolution and refresh change together on a mode switch, so they are set together.
/// `refreshHz` = 0 means the card doesn't report its timing (CGA/MDA/EGA today) —
/// the preset's rate then stands in.
@_cdecl("crt_bridge_set_signal")
public func crt_bridge_set_signal(_ ref: UnsafeMutableRawPointer,
                                  _ activeW: Int32,
                                  _ activeH: Int32,
                                  _ refreshHz: Float) {
    let state = bridgeState(ref)
    let content = SIMD2(max(1, Int(activeW)), max(1, Int(activeH)))
    // Ignore absurd rates rather than time the beam against garbage; 0 = not reported.
    let hz: Float = (refreshHz > 20.0 && refreshHz < 200.0) ? refreshHz : 0.0

    // Only a REAL sync change counts. The CRTC's derived rate jitters in the last
    // decimal (70.086 vs 70.087 on the same mode); a tube would not re-lock over a
    // millihertz.
    let resolutionChanged = content != state.contentSize
    let refreshChanged    = abs(hz - state.signalRefreshHz) > 0.05   // Hz
    guard resolutionChanged || refreshChanged else { return }

    state.contentSize = content
    state.signalRefreshHz = hz
    reconfigure(state)
}

/// The drawable the picture is presented into, in device pixels.
@_cdecl("crt_bridge_set_drawable_size")
public func crt_bridge_set_drawable_size(_ ref: UnsafeMutableRawPointer,
                                         _ width: Int32,
                                         _ height: Int32) {
    let state = bridgeState(ref)
    let size = CGSize(width: Int(width), height: Int(height))
    guard size.width > 0, size.height > 0, size != state.drawableSize else { return }
    state.drawableSize = size
    reconfigure(state)
}

/// The HOST panel's refresh (Hz). Not the emulated card's — see crt_bridge_set_signal.
@_cdecl("crt_bridge_set_display_refresh")
public func crt_bridge_set_display_refresh(_ ref: UnsafeMutableRawPointer,
                                           _ hz: Float) {
    let state = bridgeState(ref)
    guard hz > 0 else { return }
    state.displayRefreshHz = hz
    state.filter.displayRefreshRate = hz
}

/// Report the PHYSICAL DISPLAY: `screenPtr` is an NSScreen* (or NULL for the main
/// screen). Call at init AND on every event that changes the display — window moved to
/// another screen, resolution or scaled-mode change, backing-scale change, EDR change.
/// The host's only job is to notice and report; the engine decides what to do about it.
@_cdecl("crt_bridge_update_display")
public func crt_bridge_update_display(_ ref: UnsafeMutableRawPointer,
                                      _ screenPtr: UnsafeMutableRawPointer?) {
    let state = bridgeState(ref)
    let screen: NSScreen? = screenPtr.map {
        Unmanaged<NSScreen>.fromOpaque($0).takeUnretainedValue()
    }
    state.displayEnv.updateScreen(screen ?? NSScreen.main)
    // Headroom is live state the engine reads directly; it is not part of the layout.
    state.filter.displayHeadroom = Float(state.displayEnv.edrCurrent)

    // Only the panel's REFRESH is a configuration fact (the drawable's size arrives by
    // crt_bridge_set_drawable_size). So re-declare only when it moved. This matters:
    // macOS posts a screen-parameters notification for every twitch of EDR headroom —
    // a dozen a second while EDR settles — and the host rightly reports each one. Until
    // the engine dropped its panel-PPI pitch model every report re-ran the layout here;
    // nothing in the layout depends on the panel any more.
    let hz = Float(state.displayEnv.info.maxRefreshRate)
    if hz > 0, abs(hz - state.displayRefreshHz) > 0.01 {
        state.displayRefreshHz = hz
        reconfigure(state)
    }
}

/// The panel's POTENTIAL EDR headroom (capability; 1.0 = SDR-only). The host decides
/// the layer format from this. Using CURRENT here is the classic EDR chicken-and-egg —
/// current reads 1.0 until EDR content is on screen, so the layer would never go EDR.
/// The live CURRENT headroom is what clamps the highlight ceiling, re-read per frame
/// in crt_bridge_present.
@_cdecl("crt_bridge_edr_headroom")
public func crt_bridge_edr_headroom(_ ref: UnsafeMutableRawPointer) -> Float {
    Float(bridgeState(ref).displayEnv.edrPotential)
}

// MARK: - C ABI: the phosphor pattern

/// Phosphor pattern: 0 triode, 1 stripe (aperture grille), 2 shadow mask, 3 slot mask;
/// -1 = the preset's own. Ignored by the engine on a mono tube.
@_cdecl("crt_bridge_set_phosphor_pattern")
public func crt_bridge_set_phosphor_pattern(_ ref: UnsafeMutableRawPointer, _ pattern: Int32) {
    let state = bridgeState(ref)
    state.patternOverride = pattern < 0 ? nil : min(3, pattern)
    reconfigure(state)
}

/// The pattern the engine is drawing (after the preset and the mono rule).
@_cdecl("crt_bridge_get_phosphor_pattern")
public func crt_bridge_get_phosphor_pattern(_ ref: UnsafeMutableRawPointer) -> Int32 {
    let state = bridgeState(ref)
    return state.layout?.colorPhosphorPattern
        ?? state.patternOverride
        ?? Int32(state.preset?.colorPhosphorPattern ?? 0)
}

// MARK: - C ABI: dials

@_cdecl("crt_bridge_dial_count")
public func crt_bridge_dial_count() -> Int32 {
    Int32(Dial.allCases.count)
}

/// The dial's travel. False for an unknown dial.
@_cdecl("crt_bridge_dial_range")
public func crt_bridge_dial_range(_ dial: Int32,
                                  _ lo: UnsafeMutablePointer<Float>?,
                                  _ hi: UnsafeMutablePointer<Float>?) -> Bool {
    guard let d = Dial(rawValue: dial) else { return false }
    lo?.pointee = d.range.lowerBound
    hi?.pointee = d.range.upperBound
    return true
}

/// Where the dial is now: the user's position, or the preset's if untouched.
@_cdecl("crt_bridge_get_dial")
public func crt_bridge_get_dial(_ ref: UnsafeMutableRawPointer, _ dial: Int32) -> Float {
    guard let d = Dial(rawValue: dial) else { return 0 }
    return bridgeState(ref).value(d)
}

/// Where the live preset starts the dial — what a reset returns to.
@_cdecl("crt_bridge_dial_default")
public func crt_bridge_dial_default(_ ref: UnsafeMutableRawPointer, _ dial: Int32) -> Float {
    guard let d = Dial(rawValue: dial) else { return 0 }
    return bridgeState(ref).presetValue(d)
}

/// True when the user has moved the dial off the preset.
@_cdecl("crt_bridge_dial_is_set")
public func crt_bridge_dial_is_set(_ ref: UnsafeMutableRawPointer, _ dial: Int32) -> Bool {
    bridgeState(ref).overrides[dial] != nil
}

/// Turn a dial. Clamped to its range; survives mode changes and preset switches.
@_cdecl("crt_bridge_set_dial")
public func crt_bridge_set_dial(_ ref: UnsafeMutableRawPointer, _ dial: Int32, _ v: Float) {
    guard let d = Dial(rawValue: dial), v.isFinite else { return }
    let state = bridgeState(ref)
    state.overrides[dial] = clamp(v, d.range)
    applyDial(state, d)
}

/// Put a dial back on the preset.
@_cdecl("crt_bridge_reset_dial")
public func crt_bridge_reset_dial(_ ref: UnsafeMutableRawPointer, _ dial: Int32) {
    guard let d = Dial(rawValue: dial) else { return }
    let state = bridgeState(ref)
    guard state.overrides.removeValue(forKey: dial) != nil else { return }
    applyDial(state, d)
}

// MARK: - C ABI: status

/// One line saying what the tube is doing — the signal it is locked to, what the
/// engine laid out for it, and the panel's headroom. For the host's options dialog:
/// this is a diagnostic host, and the numbers that explain a picture should be
/// readable without opening a log. Returns the UTF-8 length written (excluding NUL).
@_cdecl("crt_bridge_describe")
public func crt_bridge_describe(_ ref: UnsafeMutableRawPointer,
                                _ buffer: UnsafeMutablePointer<CChar>?,
                                _ capacity: Int32) -> Int32 {
    guard let buffer = buffer, capacity > 1 else { return 0 }
    let state = bridgeState(ref)
    var text = "No picture yet"
    if let l = state.layout {
        let hz = state.filter.parameters.timing.crtRefreshRate
        let rate = (state.signalRefreshHz > 0 || !(state.preset?.multiSync ?? false))
            ? String(format: "%.2f Hz", hz)
            : String(format: "%.2f Hz (preset — card reports none)", hz)
        let pitch = Float(l.viewport.height) / Float(max(1, l.scanlineCount))
        text = String(
            format: "Signal %d×%d @ %@  ·  %d lines%@, %.2f px each  ·  buffer %d×%d  ·  picture %.0f×%.0f px  ·  headroom %.2f of %.2f",
            state.contentSize.x, state.contentSize.y, rate,
            l.scanlineCount, l.interlaced ? " interlaced" : "", pitch,
            l.phosphorWidth, l.phosphorHeight,
            Float(l.viewport.width), Float(l.viewport.height),
            Float(state.displayEnv.edrCurrent), Float(state.displayEnv.edrPotential))
    }
    let utf8 = Array(text.utf8.prefix(Int(capacity) - 1))
    utf8.withUnsafeBufferPointer { src in
        buffer.withMemoryRebound(to: UInt8.self, capacity: utf8.count + 1) { dst in
            if let base = src.baseAddress { dst.update(from: base, count: utf8.count) }
            dst[utf8.count] = 0
        }
    }
    return Int32(utf8.count)
}

// MARK: - C ABI: per-frame

/// Run the CRT and put it on the host's drawable — the whole display tail, in the engine.
///
/// The host must NOT scale, encode or aspect-fit the picture itself: the scanline comb
/// and the mask sit at the output grid's Nyquist, and the engine's linear >1.0 output
/// has to be encoded to match whatever the drawable actually is (HostContract §4, §5).
///
/// `sdrEncoded` describes the DRAWABLE, and only the host knows it:
///   false → extended-linear float drawable (rgba16Float + extendedLinear*). The display
///           pass draws STRAIGHT INTO the drawable, in the engine's own viewport: it
///           already renders at output resolution with the mask and the comb integrated
///           over the pixel, so there is nothing left to band-limit and no intermediate
///           surface to write and re-read.
///   true  → 8-bit gamma drawable (bgra8Unorm + DisplayP3/sRGB). The display pass
///           renders to a viewport-sized float surface and DisplayCompositor soft-clips
///           the above-white peaks and applies the BT.709 OETF. Writing linear here
///           reads DARK, and no brightness or contrast setting can rescue it.
///
/// The picture is placed in the ENGINE's viewport (aspect-preserving), so the host does
/// not compute an aspect fit either.
@_cdecl("crt_bridge_present")
public func crt_bridge_present(_ ref: UnsafeMutableRawPointer,
                               _ inputPtr: UnsafeMutableRawPointer,
                               _ time: Float,
                               _ targetPtr: UnsafeMutableRawPointer,
                               _ cmdPtr: UnsafeMutableRawPointer,
                               _ sdrEncoded: Bool) -> Bool {
    let state = bridgeState(ref)
    guard let input = object(inputPtr, as: MTLTexture.self),
          let target = object(targetPtr, as: MTLTexture.self),
          let cmd = object(cmdPtr, as: MTLCommandBuffer.self) else {
        NSLog("[CRTBridge] present: bad input/target/commandBuffer")
        return false
    }
    guard state.layout != nil else { return false }

    // Advance the tube one field. `simulate`, not `render`: this host draws its own
    // display surface below, and `render` would also draw a display pass at the
    // phosphor buffer's resolution only to have it thrown away.
    guard state.filter.simulate(inputTexture: input, time: time, commandBuffer: cmd) else {
        return false
    }

    // Highlight ceiling: the tube's peaks get the panel's LIVE headroom, up to the
    // user's allowance; on an SDR panel this is exactly the SDR curve. The headroom is
    // live state (it rises when the system engages EDR for our layer and moves with
    // display brightness), so it is re-read every frame.
    state.displayEnv.refreshEDR()
    let ceiling = min(max(1.0, state.filter.parameters.display.peakAllowance),
                      max(1.0, Float(state.displayEnv.edrCurrent)))

    // The engine's own whole-pixel aspect fit, mirrored from the layout by configure.
    let viewport = state.filter.scalingManager.viewport

    if !sdrEncoded && target.pixelFormat == .rgba16Float {
        return state.filter.renderDisplay(to: target, viewport: viewport,
                                          commandBuffer: cmd, highlightCeiling: ceiling)
    }

    // ---- 8-bit drawable: surface + compositor (the SDR encode) ----
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

    let vw = Int(viewport.width.rounded()), vh = Int(viewport.height.rounded())
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
    guard let surface = state.displaySurface,
          state.filter.renderDisplay(to: surface, commandBuffer: cmd,
                                     highlightCeiling: ceiling) != nil else {
        return false
    }
    // The surface is already viewport-sized, so the compositor runs 1:1: it places the
    // picture and applies the drawable's transfer.
    compositor.composite(crtOutput: surface, to: target, viewport: viewport,
                         commandBuffer: cmd)
    return true
}
