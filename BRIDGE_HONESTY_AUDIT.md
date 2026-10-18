# Bridge/CRTEngine boundary audit

## 1. Verdict

The bridge is mostly honest on the signal side and still lies on the display side. The archetype fix (pixel-clock-derived refresh through `crt_bridge_set_signal`) is real and works — for SVGA. Where it still lies, it lies in three distinct ways: it **guesses facts it can't be bothered to wire up** (the 70/60 refresh table is still live and still wrong for exactly the CGA/MDA/EGA cards that reach it, even though every input to `vid_svga.c`'s formula already exists in scope in `vid_ega.c`/`vid_cga.c`); it **throws away facts the host correctly reports** (`crt_bridge_set_display_refresh` is dead API — clobbered one statement later, and on every mode change, by the panel's *maximum* FPS); and it **reports a tautology as a physical measurement** (`backingToPanelScale` is algebraically pinned at 1.0, so the engine's panel-anchored mask path — the thing that exists to kill crosshatch — never fires on a scaled desktop). One further honesty problem is structural rather than a bug: `mon_composite` is a signal fact 86Box publishes and the ABI has no field to carry it, so the monitor is left inferring its own input standard from its own preset.

---

## 2. Findings

### CLASS (a) — INVENTS A FACT

---

#### A1. The fabricated 70/60 refresh table is still live for CGA/MDA/EGA — and it is inverted for exactly those cards
**CONFIRMED (3/3) · severity: high**

**Now:** `CRTBridge.swift:134-135`
```swift
if state.signalRefreshHz > 0 { return state.signalRefreshHz }
return contentH < 480 ? 70.0 : 60.0
```
`mon_signal_refresh_hz` has exactly two writes tree-wide — `vid_svga.c:1141` and `:1144`, both behind `if (svga->monitor != NULL)` at `:1138`. `qt_metalrenderer.mm:280` reads `monitors[r_monitor_index].mon_signal_refresh_hz` unconditionally for **every** card, so on CGA/MDA/EGA it reads a permanent `0.0` → `metal_presenter.mm:352` pushes 0.0 → `CRTBridge.swift:499` rejects it (`refreshHz > 20.0 && < 200.0`) → line 135 guesses.

**Truth, and where it lives:**
- EGA — `vid_ega.c:725-727` produces `_dispontime`/`_dispofftime` (the same `disptime`/`crtcconst` products as `vid_svga.c:1121-1123`); `ega->vtotal` is resolved at `vid_ega.c:567-576` (+ the `>>1`/`<<1` fixups at `:685-691`). Every term of `vid_svga.c:1141`'s `(cpuclock * 2^32) / ((_dispontime + _dispofftime) * vtotal)` is in scope at `vid_ega.c:727`. There is simply no assignment line.
- CGA — `vid_cga.c:259-263` produces the same pair scaled by `CGACONST` (`pit.h:120`, same `cpuclock/pixelclock*2^32` unit as VGACONST); the frame's line count is `(crtc[CGA_CRTC_VTOTAL]+1)*(crtc[MAX_SCANLINE]+1) + crtc[CGA_CRTC_VTOTAL_ADJUST]` (`vid_cga.h:39-40`).

**What breaks:** the guess is not merely imprecise on these cards, it is **inverted**. `<480 → 70 Hz` is the VGA 720x400 text convention — the one case that never reaches the fallback, because `vid_svga.c` reports the truth. The cards that do reach it are the ones for which it is false:

| Mode | Real | Guess | Error |
|---|---|---|---|
| CGA 320x200 / 640x200 | ~59.92 Hz | 70 | +17% |
| EGA 640x350 (16.257 MHz, `vid_ega.c:659`) | ~57.8 Hz | 70 | +21% |
| MDA/Hercules 720x350 | 50 Hz | 70 | +40% |

`parameters.timing.scanRate` (`CRTBridge.swift:206`) drives beam sweep position (`PhosphorSimulation.h:150-152`: `pixelsPerSecond = totalPixels * scanRate`) and `crtRefreshRate` (`:207`) drives field cadence and `broadcastFrameTime` (`CRTFilter.swift:317, :459, :476`). A CGA tube told it runs at 70 Hz sweeps 17% too fast and decays phosphor against a 14.3 ms frame instead of 16.7 ms — wrong trail length, mistimed beam. This is the refresh archetype, unfixed, on a parallel code path.

**Fix sketch:** add `ega->monitor->mon_signal_refresh_hz = ...` at `vid_ega.c:727` and the CGA equivalent after `vid_cga.c:263`, using the identical formula as `vid_svga.c:1141`. Then delete `CRTBridge.swift:135` outright — with no writer left unwired, the fallback has no reason to exist, and a hard 0 is more honest than a wrong number.

---

#### A2. `applyDisplayEnvironment` overwrites the host's reported display refresh with the panel's *maximum* refresh
**CONFIRMED (2/3 real — one dissent on consequence only) · severity: high**

**Now:** `CRTBridge.swift:170`
```swift
state.filter.displayRefreshRate = Float(env.info.maxRefreshRate)
```
`maxRefreshRate` is `screen.maximumFramesPerSecond` — an `Int`, the panel's *ceiling* (`DisplayEnvironment.swift:36`, assigned `:310`).

**Truth, one field away in the same struct:** `DisplayEnvironment.swift:37` `public let exactRefreshRate: Double`, built at `:293-298` from `CGDisplayCopyDisplayMode(displayID).refreshRate` — the current mode's real rate. Also reported independently by the host at `qt_metalrenderer.mm:183` (`screen()->refreshRate()`).

**What breaks:** the ordering makes `crt_bridge_set_display_refresh` dead API.
```objc
qt_metalrenderer.mm:183  presenter->setDisplayRefresh(float(screen()->refreshRate()));  // real, current
qt_metalrenderer.mm:184  presenter->updateDisplay((__bridge void *) nsScreen);          // clobbers it
```
`setDisplayRefresh` (`metal_presenter.mm:551`) → `CRTBridge.swift:516` sets the field; `updateDisplay` → `crt_bridge_update_display` (`:542`) → `applyDisplayEnvironment` overwrites on the very next statement. Every reporting path runs both in this order (`qt_metalrenderer.mm:117, :202, :209, :216, :263`). The header at `crt_bridge.h:63-64` promises "Set the HOST display's refresh rate (Hz) for correct field cadence" — an API whose effect is unconditionally discarded.

On a 120 Hz ProMotion panel with the desktop at 60, or any 59.94 Hz mode, the engine is told the display refreshes faster than it does. Consumers: `CRTFilter.swift:698` (`rateRatio = fieldRate / displayRefreshRate`, gating progressive beam paint at the 0.4 threshold — the comment at `:695-697` shows this exact case is what it discriminates) and `:1115` (`displayT = 1.0 / displayRefreshRate` → `displayHoldTime`). Told 120 at 60, the engine advances half the phosphor decay per frame: trails read twice as long.

> **Honest note on the dissent:** one verifier accepted every mechanical claim but argued the *visible* consequence is smaller than stated, on the grounds that the ProMotion/59.94 deltas are modest in practice. The mechanism and the dead-API finding are not in dispute; the magnitude of the trail-length symptom is. Treat the "twice as long" figure as the worst case (120-max / 60-actual), not the typical one.

**Fix sketch:** in `applyDisplayEnvironment`, read `env.info.exactRefreshRate`, not `maxRefreshRate`. Then delete `crt_bridge_set_display_refresh` (`CRTBridge.swift:512-517`, `crt_bridge.h:64`) and the host call at `qt_metalrenderer.mm:183` — the engine already measures this better than Qt does, and two writers for one display fact is the drift the archetype fix removed on the signal side. (A2 and D1 below are the same defect seen through two lenses; one fix closes both.)

---

#### A3. HDR boost latches `.forceOn`, so `edrBoost` stops being a display fact and is applied unclamped by real headroom
**CONFIRMED (3/3) · severity: high**

**Now:** `CRTBridge.swift:606-607`
```swift
state.displayEnv.edrMode = .forceOn
state.displayEnv.manualEDRBoost = v
```
`DisplayEnvironment.edrMultiplier` then returns `manualEDRBoost` unconditionally for `.forceOn` (`DisplayEnvironment.swift:121-122`) — it never consults `edrCurrent`. `applyDisplayEnvironment` pushes it straight through: `CRTBridge.swift:172-173`.

**Truth:** `DisplayEnvironment.swift:192` — `edrCurrent = screen.maximumExtendedDynamicRangeColorComponentValue`, the live AppKit fact, re-read on every `updateScreen`, and surfaced by the bridge itself at `CRTBridge.swift:550`.

**What breaks:** the doc comment at `CRTBridge.swift:598-601` asserts "the mask compensation is still clamped by the panel's ACTUAL headroom inside the engine, so asking for 3.0 on a display that cannot deliver it does not blow the picture out." **That is false for `edrBoost`.** Only `stripeBrightnessBoost` is headroom-clamped (`EDRCompensation.swift:81-89`, `peakSafe = 1.0 + (headroom-1.0)*0.6`). `edrBoost` reaches the shader raw: `CRTFilter.swift:1056` → `Shaders.metal:437` `finalColor *= crtParams.edrBoost` — no clamp, no headroom term (`LightCRT.h:55` likewise).

Drag the window from an XDR panel to SDR (or unplug it, or let macOS drop headroom on battery): AppKit reports `edrCurrent = 1.0`, `reportDisplay` fires (`qt_metalrenderer.mm:198-216, 261-263`), `MetalPresenter::updateDisplay` *correctly* drops the layer to BGRA8Unorm + DisplayP3 because `crt_bridge_edr_headroom` returns the real 1.0 (`metal_presenter.mm:658-659`) — and `edrBoost` stays pinned at e.g. 2.5. Every pixel is multiplied 2.5x into an SDR drawable, then `softClipHighlights` (`Shaders.metal:754-755`, knee 0.85) crushes everything above ~0.34 linear into the shoulder: washed-out, detail-free, on a panel that reported no headroom. Second consequence: the HDR mask-softening term keys off the same number — `saturate((crtParams.edrBoost - 1.0) * crtParams.hdrMaskDim)` (`Shaders.metal:292, 332`) — so the mask is dimmed toward flat on an SDR panel as if it were HDR.

There is no path back to `.auto`: the options dialog exposes only the boost slider (`qt_metalrenderer.mm:379`), the legacy toggle that would restore `.auto` (`CRTBridge.swift:589`) is out of the UI, and `loadSettings` applies `crt.hdrenabled` **before** `crt.hdrboost` (`metal_presenter.mm:641-642`), so once persisted the state is `.forceOn` on every launch.

**Fix sketch:** keep `manualEDRBoost` as the user's *ask* and let the engine multiply it against live `edrCurrent`; at minimum clamp `edrBoost` by `max(1.0, edrCurrent)` where the panel reports 1.0. The boost slider should not imply an EDR *mode*.

---

#### A4. `panelScale` is algebraically always 1.0 — a tautology reported as a physical panel fact
**CONFIRMED (3/3, one empirically) · severity: high**

**Now:** `CRTBridge.swift:306-308`
```swift
let framebufferW = Float(info.logicalSize.width) * Float(info.backingScaleFactor)
let panelNativeW = Float(info.nativePixelWidth)
let panelScale: Float = (framebufferW > 1 && panelNativeW > 1) ? (panelNativeW / framebufferW) : 1.0
```
Both operands are the same quantity. `info.logicalSize` = `screen.frame.size` (points) and `info.backingScaleFactor` = `screen.backingScaleFactor` (`DisplayEnvironment.swift:289-290`). `info.nativePixelWidth` is **not** the panel's native width — it is `CGDisplayCopyDisplayMode(displayID).pixelWidth` (`DisplayEnvironment.swift:294-295`), the *current mode's framebuffer* width, which is by definition `mode.width x backingScale`. The field name is the only thing that says "native".

Verified empirically on this Mac (MBP 14, panel 3024x1964). Enumerating every HiDPI mode via `CGDisplayCopyAllDisplayModes`: `pixelWidth == width * 2` for **every** mode without exception, including the scaled modes the comment is specifically about —
```
1512x982 pts -> 3024x1964 px   (default, panel-native)
1800x1169 pts -> 3600x2338 px  ("More Space" — framebuffer 3600 on a 3024 panel)
```
The live computation returns exactly `panelScale = 1.0`. The comment at `CRTBridge.swift:302-308` claims "1.0 in native display mode; **< 1** in a scaled desktop mode … This is a FACT WE REPORT, not a decision." It reports a constant.

**Truth:** **currently computed nowhere.** `DisplayInfo` has the physical size (`CGDisplayScreenSize`, `DisplayEnvironment.swift:302`) but not the native mode. The fact *is* reachable: the panel-native mode carries `kDisplayModeNativeFlag` (0x02000000) in `CGDisplayMode.ioFlags` — verified on this machine, it returns 3024x1964, distinct from the 3600 the bridge uses.

**What breaks:** the engine's `.displayOnly` panel-anchored mask path is dead code in the only case it exists for. `ScalingManager.swift:418` does `drawablePxPerStripe = panelPxPerStripe / max(0.1, inputs.backingToPanelScale)` precisely to widen the stripe when the OS downscales framebuffer→panel; the divisor never fires. Concretely, this Mac in "More Space" (fb 3600, panel 3024, downscale 0.84), default 1x mask scale:

| | drawable px/stripe | → physical px/stripe |
|---|---|---|
| bridge (panelScale 1.0) | 1.000 | **0.840** |
| correct (panelScale 0.84) | 1.190 | 1.000 |

A 0.84-physical-pixel stripe is below the panel's Nyquist: the mask cannot be resolved and beats against the panel grid — the harsh-crosshatch/moiré class, unfixable from mask-scale or mask-softening because the anchor number is wrong before those apply. Silent in native mode (where 1.0 happens to be correct), which is why it survives testing. `logLayout` prints `panelScale` (`CRTBridge.swift:291`) and it reads 1.0000 on every machine, forever.

> One verifier voted this dead **on the availability lens specifically** — the true fact is not currently computed anywhere, so under a strict "the bridge fails to use an existing fact" reading it isn't class (a). The other two (one of whom compiled a probe against this machine's displays) accepted it as a real degenerate-state defect. I report it because the arithmetic is not in dispute by anyone, and the flag-based route to the real fact is verified to work.

**Fix sketch:** populate `nativePixelWidth` in `DisplayEnvironment` from the mode carrying `kDisplayModeNativeFlag` (or the max `pixelWidth` across `CGDisplayCopyAllDisplayModes` with `kCGDisplayShowDuplicateLowResolutionModes`), not from the current mode. Same for `pixelsPerInch` (`DisplayEnvironment.swift:304-307`), which is currently the *framebuffer's* PPI.

---

#### A5. The card's composite-vs-RGB output is a signal fact 86Box publishes and no ABI carries
**PLAUSIBLE (added by completeness critic, not run through the 3-lens verify) · severity: medium**

**Now:** `applyPresetInternal` (`CRTBridge.swift:189-250`) sets scanRate, crtRefreshRate, interlaced, scanlineCount and the VGA encoder — but never touches `parameters.broadcast.videoStandard`. So the standard is whatever `applyPreset` left, and `applyPreset` takes it from the **monitor**: `CRTFilter+ApplyPreset.swift:44-45` (`preset.supportedVideoStandards.first ?? .digital`) and `:48-50` derives the whole composite pipeline switch from it (`isCompositeLike` → `enableCompositeBroadcast`). `VideoStandard.swift:13-22` makes this a *signal-type* enum by its own definition.

**Truth:** `video.h:163` `atomic_bool mon_composite;` — set from the card's own `display_type` at `vid_cga.c:775` (`cga->composite = (display_type != CGA_RGB)`) and published at `:808`; identically at `vid_tandy.c:991`, `vid_pcjr.c:761`, `vid_cga_compaq.c:458`, `vid_cga_colorplus.c:361`, `vid_cga_quadcolor.c:850`, `vid_cga_v6355.c:951` (cleared for all at `vid_table.c:431`). 86Box's own UI already reads it (`qt_mainwindow.cpp:365`). The host is already indexing that exact struct one line away for the sibling fact — `qt_metalrenderer.mm:280` reads `mon_signal_refresh_hz`, and `mon_composite` sits in the same declaration block (`video.h:135-163`).

**What breaks:** there is no route. The whole-cable call is `crt_bridge_set_signal(CRTBridgeRef, int activeW, int activeH, float refreshHz)` (`crt_bridge.h:60`) — resolution and refresh only. With the shipped default preset ("VGA monitor", `metal_presenter.mm:566`, standards `[.digital,.vga,.component]` per `PresetLoader.swift:88`), a CGA/Tandy/PCjr machine configured for composite leaves the engine at `.digital`/`.vga` with `enableCompositeBroadcast = 0` forever: a clean TTL response to a composite signal, and the only thing that moves it is the user manually picking the "NTSC color" preset — i.e. **the monitor deciding what signal it is being sent**, the exact inversion this boundary exists to prevent.

**Fix sketch:** widen the ABI — `crt_bridge_set_signal_ex(..., bool composite)` or a separate `crt_bridge_set_signal_standard()` — and report `monitors[r_monitor_index].mon_composite` from `qt_metalrenderer.mm:280` alongside the refresh. **Report the fact; do not unilaterally switch on the engine's composite encode.** 86Box already runs its own composite decode into the framebuffer (`vid_cga.c:429`), so the engine needs the fact in order to decide correctly, and the host may need to suppress 86Box's decode. That negotiation is the engine's to make — which is precisely the division of labour. Today it cannot make it, because the fact never crosses the cable.

---

### CLASS (c) — DUPLICATES ENGINE POLICY

---

#### D1. `filter.displayRefreshRate` has two writers with two derivations
**CONFIRMED (2/3 real — same dissent shape as A2) · severity: medium**

This is A2 seen from the duplication side; recorded separately because it adds two facts A2 doesn't:

1. **The clobber is not just an ordering accident — it is re-armed on every mode change.** `applyDisplayEnvironment` is also called from `applyPresetInternal` (`CRTBridge.swift:247`), so every 86Box mode switch (`crt_bridge_set_signal` → `applyPresetInternal` → `applyDisplayEnvironment`) silently overwrites whatever the host reported, as do `set_phosphor_pattern` (`:638`), `set_hdr_enabled` (`:590`) and `set_hdr_boost` (`:608`). So even a host that called `setDisplayRefresh` *after* `updateDisplay` would only hold the value until the next mode set.
2. **`exactRefreshRate` and `isVariableRefreshRate` are captured and read by nothing.** Grep across `CRTEngine/Sources` returns only their definition sites (`DisplayEnvironment.swift:37`/`:344`, `:313`/`:349`). The engine already did the work; nobody collects it.

**Fix sketch:** as A2 — single writer, `env.info.exactRefreshRate`, delete the C entry point.

---

#### D2. The bridge re-implements the engine's chroma-notch pattern gate
**CONFIRMED (2/3 real — one dissent: "no symptom today") · severity: medium**

**Now:** the bridge decides *which* patterns need the notch, in two places:
- `CRTBridge.swift:237-239` — `let pattern = effectivePattern(state); state.filter.parameters.display.chromaNotchStrength = (pattern == 1 || pattern == 3) ? 1.0 : 0.0`
- `CRTBridge.swift:636-637` — the same ternary in `crt_bridge_set_phosphor_pattern`.

**Truth:** the engine applies the identical gate one layer down and owns the reasoning: `CRTFilter.swift:836-838`
```swift
let pattern = crtUniforms[0].colorPhosphorPattern
let notchStrength = parameters.display.chromaNotchStrength
if notchStrength > 0.0, pattern == 1 || pattern == 3, let notch = chromaNotch {
```
with `CRTFilter.swift:834-835`: *"Stripe(1)/slot(3) only — shadow(2) is already resample-robust and triode(0) has no mask. **Host opts in via display.chromaNotchStrength.**"* The parameter is a *strength the host opts into*; the which-patterns test is engine policy, and it exists verbatim on both sides. The engine also owns the tuning (`tripletPx = max(1.0, crtUniforms[0].stripePitch) * 3.0`, `:839`).

**What breaks:** nothing today — the copies agree, and the dissenting verifier is right that output is bit-identical. The finding is drift exposure, which is the class-(c) definition: if the engine ever widens the gate (shadow mask needs the notch after a pitch change) the engine's new policy is **unreachable from 86Box** — the bridge has already pinned strength to 0.0 for that pattern, so `notchStrength > 0.0` fails first and 86Box alone keeps the rainbow moiré with nothing on the engine side to indicate why. The inverse drift is equally silent: drop slot(3) and the bridge keeps pushing 1.0 into a dead write that still looks live. Same shape as the `stripeBrightnessBoost` duplication the bridge already removed and documents against at `CRTBridge.swift:175-178`.

**Fix sketch:** write `chromaNotchStrength = 1.0` unconditionally at both sites and delete the ternary. The engine's gate already zeroes patterns 0 and 2.

---

#### D3. `hdrMaskDim` is force-pushed from a bridge-local default on every preset apply
**PLAUSIBLE (2/3 — one dissent on mechanism, see below) · severity: low**

**Now:** every entry in `applyUserOverrides` is guarded by `if let v = …` so an untouched control leaves the engine's value alone (`CRTBridge.swift:154-161`). `hdrMaskDim` is the exception — `CRTBridge.swift:162` is unconditional:
```swift
state.filter.parameters.display.hdrMaskDim = state.hdrMaskDim
```
and `state.hdrMaskDim` is a non-optional seeded by the bridge itself: `Float(ProcessInfo.processInfo.environment["CRT_HDR_MASK_DIM"] ?? "") ?? 0.5` (`CRTBridge.swift:84-85`). The `0.5` is a verbatim copy of the engine's own tuned default: `CRTFilter.swift:99` `public var hdrMaskDim: Float = 0.5 // .displayOnly: EDR-driven mask fade strength (0=off); tames HDR crosshatch harshness`.

**What breaks:** nothing today; both constants are 0.5. The bridge has pinned the engine's HDR mask-fade default from the outside — if CRTEngine retunes it, 86Box keeps 0.5 forever, since `applyUserOverrides` re-asserts after every `applyPreset`, which a mode change re-runs (`CRTBridge.swift:249, :509`). A user who never touched the control gets the bridge's number, not the engine's.

> **The dissent is partly right and worth recording:** the third verifier established that `CRTFilter+ApplyPreset.swift:96-104` writes only brightness/contrast/saturation/colorLevel/vignetteStrength/stripeBrightnessBoost — `hdrMaskDim` appears nowhere in `applyPreset`. So line 162 does **not** clobber a per-preset engine choice on each apply; it only ever overwrites the engine's *initial default*. That narrows the finding to "the bridge pins the engine's default", which is why it's ranked low. It does not eliminate it: the pin is real and the retune scenario stands.

**Fix sketch:** make `state.hdrMaskDim` a `Float?` seeded `nil` (env var sets it when present), and guard line 162 with `if let` like its eight neighbours.

---

### CLASS (e) — DEGENERATE STATE

---

#### E1. Every mode-set transient triggers a full phosphor reallocation with two blocking GPU waits; the engine's documented debounce seam is never used
**CONFIRMED (2/3 real — one dissent, medium confidence, on impact framing) · severity: high**

**Now:** `recomputeLayout` ends in `state.filter.apply(chosen)` (`CRTBridge.swift:332`) — always with the default `resize: true`. It is the only `filter.apply` call site in the bridge, and no call site anywhere passes `resize:`.

`CRTFilter.apply` (`CRTFilter+ApplyPreset.swift:161` signature; the gate is at `:185`):
```swift
if resize, width != layout.phosphorWidth || height != layout.phosphorHeight {
    self.resize(width: layout.phosphorWidth, height: layout.phosphorHeight)
}
```
→ `CRTFilter.resize` (`CRTFilter.swift:925`) → `PhosphorSimulator.resize` (`PhosphorSimulator.swift:259`), which reallocates the brightness texture plus a `width*height*4` generation buffer and zeroes both:
- `clearPhosphorTextureNow()` — `PhosphorSimulator.swift:382`, `waitUntilCompleted()` at `:393`
- `blitFillBuffers([gBuf], …)` — `:398`, `waitUntilCompleted()` at `:406`

`blitFillBuffers`' own comment states the assumption the bridge breaks (`PhosphorSimulator.swift:397`): *"Submits and waits synchronously — only called during init/resize."*

**Truth / the seam:** `CRTFilter+ApplyPreset.swift:150-158` documents it explicitly — *"`resize: false` opts out of the phosphor buffer reallocation. Hosts use this during window-resize debounce paths where the buffer reallocation is deferred … the parameter writes still happen so beam/stripe/visibility track the new drawable shape immediately, but the expensive reallocation waits for a debounced full apply."* The bridge never passes it.

**What breaks:** the path is fully unthrottled. `metal_presenter.mm:346` fires `crt_bridge_set_signal` on any srcW/srcH change; `CRTBridge.swift:504-509` has only an equality/0.05 Hz dedup — no debounce, no coalescing — and calls `applyPresetInternal`, which rebuilds the ScalingManager (`:241`), the VGA encoder texture (`:227`, `VGAEncoder.swift:126-131`) and the phosphor chain. The sizes genuinely differ per transient, so the resize fires every time. At a 3840-wide viewport (`ScalingManager.swift:311-315, 337, 342, 361`):

| signal | pps | phosphor buffer |
|---|---|---|
| 640x480 | 6 | 3840x2880 (11.1 Mpx) |
| 640x2001 | 2 | 5336x4002 (**21.4 Mpx — 1.93x steady state**) |
| 640x771 | 4 | 4112x3084 (12.7 Mpx) |
| 1024x739 | 4 | 3944x2956 |
| 1024x718 | 5 | 4787x3590 |

The reported burst (640x2001 → 640x771 → 640x2001 → 1024x739 → 1024x718 → 1024x768) performs ~6 distinct full reallocations back-to-back, each at a different size, each followed by two blocking `waitUntilCompleted`. So a DOS mode switch stalls the presentation thread on ~12 synchronous GPU round-trips while allocating and discarding buffers up to 21.4 Mpx for garbage rasters never seen. And because `PhosphorSimulator.resize` zeroes the brightness texture and generation buffer (`:277-278`), each transient wipes accumulated persistence — the tube's decay state is destroyed and re-seeded from black several times per mode set, so the picture flashes/blacks out on every 86Box resolution change instead of a real tube's brief loss of sync.

> **Dissent note:** the third verifier accepted every citation (flagging that `:161` is the signature and `:185` is the actual gate) and voted no at *medium* confidence on impact framing rather than mechanism. The mechanism is not disputed.

**Fix sketch:** two independent halves, either of which helps. (1) Debounce `crt_bridge_set_signal` in the bridge: on a signal change call `applyPresetInternal` with `resize: false` so beam/stripe/visibility track immediately, and schedule the full `resize: true` apply after the raster has been stable for a frame or two. (2) Cheaper alone: hold the phosphor buffer at the steady-state size and refuse to grow it for a raster that hasn't survived N frames. This is the mode-set-transient item from the known-open list, but with the actual cost named: it isn't just "a rebuild", it's 12 blocking GPU waits, a 1.93x transient allocation, and the phosphor state wiped — and the engine already shipped the API to avoid it.

---

## 3. Confidence summary

**CONFIRMED — all three verification lenses agreed the defect is real:**
- A1 — CGA/MDA/EGA refresh fallback (high)
- A3 — `edrBoost` unclamped by real headroom (high)
- A4 — `panelScale` pinned at 1.0 (high; one lens dissented on *class*, not arithmetic — see note)

**PLAUSIBLE — 2 of 3 lenses; dissent recorded inline:**
- A2 / D1 — display refresh clobber & dead API (high / medium) — dissent on symptom magnitude only; mechanism undisputed
- E1 — mode-set realloc storm (high) — dissent on impact framing only; mechanism undisputed
- D2 — chroma-notch gate duplication (medium) — dissent: no symptom today (correct; it's drift exposure)
- D3 — `hdrMaskDim` pinning (low) — dissent materially narrowed the finding; narrowed version reported

**UNVERIFIED — added late by the completeness pass, not adversarially checked:**
- A5 — `mon_composite` has no ABI route (medium). Citations were spot-checked but this one did not go through the 3-lens verify. Treat the file:line claims as good and the framing as un-stress-tested.

**Not re-reported** (known open, no new precision found): `preset.interlaced` vs `svga->monitor->mon_interlace`; host-side convergence scaling. The mode-set-transient item *is* re-reported as E1, because the finder added the blocking-wait count, the 1.93x allocation, the phosphor wipe, and the unused engine seam.

---

## 4. Considered and dismissed

Each was investigated with citations and killed on availability, mechanism, or consequence:

- **Fixed-frequency presets discard the card's true refresh** — dead: `scanRate` has no rendering consumer (written `CRTFilter.swift:1008`, declared `ShaderTypes.h:142`, read nowhere).
- **Drawable colour space hardcoded DisplayP3 instead of asked of NSScreen** — mechanically accurate (`metal_presenter.mm:667-669`), but no consequence survived.
- **`signalScanlines()` collapses signal-vs-tube; `tubeNativeScanlines` never passed** — the engine input is real (`ScalingManager.swift:84`) but the surrounding code refutes the impact.
- **VGA encoder configured with the tube's raster as "the signal resolution"** — citations accurate, causation misattributed.
- **`crt_bridge_set_hdr_boost` forces `.forceOn`, bypassing headroom-aware boost** — dead as framed: `calculateAutoBoost` is `private` and takes no user parameter. (The *unclamped-shader* version of this survives as A3.)
- **`vgaEncoder.configure(sourceWidth:sourceHeight:)` is dead — overwritten every frame** — every fact verified (`VGAEncoder.swift:155` does overwrite), but it is not a defect under the rule.
- **Bridge duplicates the engine's manual-EDR-boost range clamp** (`CRTBridge.swift:605` vs `DisplayEnvironment.swift:230`) — literally true, no reachable consequence.
- **Bridge duplicates the engine's `displayMaskScale` floor** — `max(1.0,·)` composed with `max(1.0,·)` cannot drift.
- **Sharpness dial floors scanline spacing at 2.0 before the engine's inverse** — σ-asymmetry math is correct in the abstract, consequence provably nil in every reachable configuration.
- **The 20–200 Hz sync-acceptance window is invented monitor policy** (`CRTBridge.swift:499`) — the bounds *are* bridge-invented, but no consequence survived.
- **`signalScanlines` clamps to a fabricated 2048 contradicting 86Box's bound** — the premise was a misreading; `vid_svga.c:2221-2223` says 2048x2048 *is* the safe bound.