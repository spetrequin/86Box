// crt_bridge.h — flat C ABI surface for CRTEngine.
//
// This is the contract a C/C++/Obj-C++ host (e.g. an 86Box Qt renderer) compiles
// against. The implementation lives in the Swift target `CRTBridgeC` as @_cdecl
// functions; symbols resolve at link time against libCRTBridgeC.dylib. Metal
// objects cross the boundary as opaque `void *` — on the host side they are
// `id<MTL...>` passed with `(__bridge void *)`, on the Swift side they are
// recovered via Unmanaged.
//
// Two creation/preset families:
//   * crt_bridge_create / _apply_preset       — load resources via Bundle.module
//                                                (SwiftPM/Xcode hosts).
//   * crt_bridge_create2 / _apply_preset_file  — load metallib + presets from
//                                                explicit paths (CMake/.app hosts).
#ifndef CRT_BRIDGE_H
#define CRT_BRIDGE_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque handle to a live CRT filter + scaling state.
typedef void *CRTBridgeRef;

// --- Creation -------------------------------------------------------------

// Create the engine. `device` is an id<MTLDevice>. phosphorW/H is the internal
// phosphor-buffer (render) resolution. Returns NULL on failure. Shaders + presets
// load from CRTEngine's own resource bundle (Bundle.module), which the app bundles
// into Contents/Resources so the engine stays unmodified.
CRTBridgeRef crt_bridge_create(void *device, int phosphorW, int phosphorH);

// --- Preset selection -----------------------------------------------------

// Configure for a named preset (e.g. "VGA monitor", "NTSC color"), loading the
// preset list via Bundle.module. contentW/H = the emulated source resolution.
// Returns false if the preset name is unknown or the bundle is missing.
bool crt_bridge_apply_preset(CRTBridgeRef ref, const char *presetName,
                             int contentW, int contentH);

// --- Dynamic state --------------------------------------------------------

// Re-apply the current preset at a new emulated resolution. Call when 86Box
// switches video mode (mon_xsize/mon_ysize change). Prefer crt_bridge_set_signal.
void crt_bridge_set_content_size(CRTBridgeRef ref, int contentW, int contentH);

// THE SIGNAL ON THE WIRE. What the emulated video card is sending: active
// resolution + its TRUE vertical refresh, straight from the CRTC
// (monitor_t.mon_signal_refresh_hz). Call on every mode change.
//
// One-way, like the real VGA cable: the card pushes, the tube reacts, nothing comes
// back. Resolution and refresh travel together because a mode change alters both at
// once. refreshHz = 0 means "this card doesn't report timings" (CGA/MDA/EGA today) —
// the bridge falls back to the VGA standards table.
//
// NOTE: this is the EMULATED CARD's refresh, not the host monitor's. For the latter
// see crt_bridge_set_display_refresh — they are different concepts, do not conflate.
void crt_bridge_set_signal(CRTBridgeRef ref, int activeW, int activeH, float refreshHz);

// Set the HOST display's refresh rate (Hz) for correct field cadence. This is the
// physical panel 86Box's window is on — NOT the emulated card's signal refresh.
void crt_bridge_set_display_refresh(CRTBridgeRef ref, float hz);

// Detect host display capabilities (EDR headroom, refresh, scale) from an
// NSScreen* (or NULL for the main screen) and push them into the engine. Call
// at init and on screen changes. Feeds the engine's LIVE headroom (peak ceiling).
void crt_bridge_update_display(CRTBridgeRef ref, void *nsScreen);

// The display's POTENTIAL EDR headroom (capability; 1.0 = SDR-only panel). The host
// decides the CAMetalLayer format from this (rgba16Float + extended linear when >1).
// NOT the live current headroom — that clamps the highlight ceiling internally,
// re-read every frame (current reads 1.0 until EDR content is on screen, so gating
// the layer on it would keep EDR permanently off — the chicken-and-egg).
float crt_bridge_edr_headroom(CRTBridgeRef ref);

// Set the fixed phosphor render width (px); higher = finer stripes/mask, more
// GPU. 0 = render at the window size. Default 2880.
void crt_bridge_set_render_resolution(CRTBridgeRef ref, int width);

// Display-only RGB mask scale (the "1x/2x/3x" control): a multiplier of the
// engine's algorithmic finest pitch. 1.0 = finest (1px per aperture-grille stripe
// = 3px triplet); 2.0 / 3.0 = coarser. Clamped [1,3]. Seeded from CRT_MASK_SCALE.
void crt_bridge_set_mask_scale(CRTBridgeRef ref, float scale);

// Peak highlights (replaces HDR on/off + boost): how far the tube's >1.0 peaks
// (mask sparkle, small-area highlights) may render above reference white. Always
// capped by the panel's LIVE headroom; the picture body is identity on every
// panel, so this can never blow out the image. 1.0 = SDR look everywhere.
void crt_bridge_set_peak_highlights(CRTBridgeRef ref, float v);   // 1.0 .. 16.0 (live-clamped by panel)

// Switch CRT preset at runtime (at the current content size, keeping user overrides).
// e.g. "VGA monitor", "NTSC color", "Green CRT monitor". Returns false if unknown.
bool crt_bridge_set_preset(CRTBridgeRef ref, const char *presetName);

// --- Picture + phosphor pattern + monitor conditions (live, for an options UI) ---
void crt_bridge_set_brightness(CRTBridgeRef ref, float v);        // -0.4 .. +0.5
void crt_bridge_set_contrast(CRTBridgeRef ref, float v);          // 0.1 .. 3.0
// Phosphor pattern: 0=triode, 1=stripe (aperture grille), 2=shadow mask, 3=slot.
void crt_bridge_set_phosphor_pattern(CRTBridgeRef ref, int pattern);
// Beam controls.
void crt_bridge_set_sharpness(CRTBridgeRef ref, float s);         // 0=soft .. 1=sharp
void crt_bridge_set_edge_focus(CRTBridgeRef ref, float v);        // 0..1
void crt_bridge_set_bloom(CRTBridgeRef ref, float v);            // 0..~0.5
void crt_bridge_set_convergence(CRTBridgeRef ref, float v);       // px, 0..~1
// Monitor conditions.
void crt_bridge_set_h_jitter(CRTBridgeRef ref, float v);          // px, 0..~3
void crt_bridge_set_v_jitter(CRTBridgeRef ref, float v);          // scanlines, 0..~2
void crt_bridge_set_shot_noise(CRTBridgeRef ref, float v);        // 0..~0.05
void crt_bridge_set_h_bandwidth(CRTBridgeRef ref, float v);       // RC rolloff β 0.2..1.0 (lower = sharper)
void crt_bridge_set_h_focus(CRTBridgeRef ref, float v);           // optical H blur σ 0..3 source px (0 = focused)
void crt_bridge_set_beam_segment(CRTBridgeRef ref, float v);      // beam temporal resolution 0..1: 1 = whole line at one instant (legacy, zero flicker), smaller = segmented dot (real sweep-time structure, flicker as the dial approaches a dot)
void crt_bridge_set_shutter(CRTBridgeRef ref, float v);          // observer integration 0..1: 1 = fused eye (steady), lower = camera shutter (rolling band / flicker)
void crt_bridge_set_scanline_smoothing(CRTBridgeRef ref, float v); // 0..1 gap-fill when output can't resolve scanlines
void crt_bridge_set_pattern_smooth(CRTBridgeRef ref, float v);     // 0..2 mask anti-alias (1 = clean default, 2 = pattern dissolved)
void crt_bridge_set_signal_noise(CRTBridgeRef ref, float v);      // 0..~0.15

// Lay the screen out for a given drawable size (the on-screen widget size).
void crt_bridge_set_drawable_size(CRTBridgeRef ref, int width, int height);

// --- Per-frame ------------------------------------------------------------

// PRESENT ONE FRAME — run the CRT and put it on the drawable. This is the call a
// display host wants: the engine owns the whole display tail.
//
// Do NOT use crt_bridge_render() and scale the result yourself. The phosphor buffer
// holds a 1px RGB mask and a scanline comb — content at Nyquist — so it must be
// band-limited on the way out at EVERY scale ratio (point-sampling it because you
// happen to be magnifying will alias, in triode too), and the engine's linear,
// above-1.0 output must be encoded to match the drawable. Both are engine policy.
//
// `sdrEncoded` describes the DRAWABLE — only the host knows this:
//   false = extended-linear float (rgba16Float + extendedLinear*) — engine writes
//           linear; the OS tonemaps above-white against the panel's EDR headroom.
//   true  = 8-bit gamma-encoded (bgra8Unorm + DisplayP3/sRGB) — engine soft-clips
//           above-white peaks and applies the BT.709 OETF.
// Writing linear into a gamma-encoded drawable reads DARK, and no brightness or
// contrast setting can correct it — it is a transfer-function mismatch.
//
// The picture is placed with the ENGINE's aspect-preserving viewport, so the host
// does not compute an aspect fit either. Returns false on failure.
bool crt_bridge_present(CRTBridgeRef ref, void *inputTexture, float time,
                        void *target, void *commandBuffer, bool sdrEncoded);

// Render one frame. `inputTexture` and `commandBuffer` are id<MTLTexture> /
// id<MTLCommandBuffer>. `time` is a monotonic seconds clock driving beam sweep
// and phosphor decay. Returns the simulated output as id<MTLTexture> (borrowed,
// owned by the engine, valid until the next render) or NULL.
// LOW-LEVEL: prefer crt_bridge_present, which also does the display tail correctly.
void *crt_bridge_render(CRTBridgeRef ref, void *inputTexture, float time,
                        void *commandBuffer);

// Run the sim and render the CRT directly into `target` (an id<MTLTexture>) at the
// target's own resolution, using the engine's display shader (its own downscale +
// mask LOD). The host presents `target` 1:1 — no host scaling of the phosphor, so
// no resample moiré. `target` should be 4:3. Returns false on failure.
bool crt_bridge_render_display(CRTBridgeRef ref, void *inputTexture, float time,
                               void *commandBuffer, void *target);

// Resize the phosphor/output buffers.
void crt_bridge_resize(CRTBridgeRef ref, int width, int height);

// Release the engine.
void crt_bridge_destroy(CRTBridgeRef ref);

#ifdef __cplusplus
}
#endif

#endif // CRT_BRIDGE_H
