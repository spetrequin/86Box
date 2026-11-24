// crt_bridge.h — flat C ABI surface for CRTEngine.
//
// This is the contract a C/C++/Obj-C++ host (the 86Box Qt Metal renderer) compiles
// against. The implementation lives in the Swift target `CRTBridgeC` as @_cdecl
// functions; symbols resolve at link time against libCRTBridgeC.dylib. Metal
// objects cross the boundary as opaque `void *` — on the host side they are
// `id<MTL...>` passed with `(__bridge void *)`, on the Swift side they are
// recovered via Unmanaged.
//
// The division of labour (CRTEngine docs/HostContract.md): the host REPORTS facts —
// the signal its card is sending, the drawable, the physical display — and DECLARES
// what the user chose — the preset, the pattern, the dial positions. The engine
// decides everything about rendering. So this header has no layout, buffer-size or
// render-resolution entry points: those are not the host's to set.
//
// Resources load via Bundle.module: 86Box's CMake build (crtbridge/build.sh) bundles
// CRTEngine's resource bundle, with a compiled default.metallib, into the .app.
#ifndef CRT_BRIDGE_H
#define CRT_BRIDGE_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque handle to a live CRT.
typedef void *CRTBridgeRef;

// --- Creation -------------------------------------------------------------

// Create the engine. `device` is an id<MTLDevice>; drawableW/H is the drawable the
// picture will be presented into, in device pixels (correct it later with
// crt_bridge_set_drawable_size). Returns NULL on failure. Nothing is drawn until a
// preset is set.
CRTBridgeRef crt_bridge_create(void *device, int drawableW, int drawableH);

// Release the engine.
void crt_bridge_destroy(CRTBridgeRef ref);

// --- Presets --------------------------------------------------------------

// The engine's bundled presets, in the engine's order. The host lists THESE instead
// of keeping its own table of names — a host-side table goes stale the day the engine
// renames or adds one. Names are valid for the life of the process; NULL past the end.
int         crt_bridge_preset_count(void);
const char *crt_bridge_preset_name(int index);

// Switch the tube (e.g. "VGA monitor", "NTSC color"). The user's dial positions are
// kept and re-applied over the new preset's starting positions. Returns false if the
// name is unknown or the resource bundle is missing.
bool crt_bridge_set_preset(CRTBridgeRef ref, const char *presetName);

// Index of the live preset in the list above, or -1 before one is set.
int  crt_bridge_current_preset(CRTBridgeRef ref);

// True when the live tube is a colour tube (it has a phosphor pattern to choose).
bool crt_bridge_is_color(CRTBridgeRef ref);

// --- The signal and the display -------------------------------------------

// THE SIGNAL ON THE WIRE. What the emulated video card is sending: active
// resolution + its TRUE vertical refresh, straight from the CRTC
// (monitor_t.mon_signal_refresh_hz). Call on every mode change.
//
// One-way, like the real VGA cable: the card pushes, the tube reacts, nothing comes
// back. Resolution and refresh travel together because a mode change alters both at
// once. refreshHz = 0 means "this card doesn't report timings" (CGA/MDA/EGA today) —
// the preset's rate then stands in.
//
// NOTE: this is the EMULATED CARD's refresh, not the host monitor's. For the latter
// see crt_bridge_set_display_refresh — they are different concepts, do not conflate.
void crt_bridge_set_signal(CRTBridgeRef ref, int activeW, int activeH, float refreshHz);

// The drawable the picture is presented into (the on-screen widget, device pixels).
void crt_bridge_set_drawable_size(CRTBridgeRef ref, int width, int height);

// Set the HOST display's refresh rate (Hz) for correct field cadence. This is the
// physical panel 86Box's window is on — NOT the emulated card's signal refresh.
void crt_bridge_set_display_refresh(CRTBridgeRef ref, float hz);

// Detect host display capabilities (EDR headroom, refresh, scale) from an
// NSScreen* (or NULL for the main screen) and push them into the engine. Call
// at init and on every display change.
void crt_bridge_update_display(CRTBridgeRef ref, void *nsScreen);

// The display's POTENTIAL EDR headroom (capability; 1.0 = SDR-only panel). The host
// decides the CAMetalLayer format from this (rgba16Float + extended linear when >1).
// NOT the live current headroom — that clamps the highlight ceiling internally,
// re-read every frame (current reads 1.0 until EDR content is on screen, so gating
// the layer on it would keep EDR permanently off — the chicken-and-egg).
float crt_bridge_edr_headroom(CRTBridgeRef ref);

// --- The phosphor pattern --------------------------------------------------

// 0 = triode, 1 = stripe (aperture grille), 2 = shadow mask, 3 = slot mask;
// -1 = the preset's own. Ignored by the engine on a mono tube.
void crt_bridge_set_phosphor_pattern(CRTBridgeRef ref, int pattern);
// The pattern the engine is drawing (after the preset and the mono rule).
int  crt_bridge_get_phosphor_pattern(CRTBridgeRef ref);

// --- Dials ------------------------------------------------------------------
//
// Every continuous user control is one of these. For each the bridge knows the range
// (the ENGINE's own, wherever the engine publishes one), where the live preset starts
// it, and where it is now — so a host's slider never restates a range or a default,
// and opens showing the truth. Labels, grouping and units are the host's business.
//
// Order must match `Dial` in CRTBridge.swift; crt_bridge_dial_count() lets the host
// check that it does.
typedef enum {
    // Picture
    CRT_DIAL_BRIGHTNESS = 0,   // master bias (DC offset); 0 = neutral
    CRT_DIAL_CONTRAST,         // master video gain
    CRT_DIAL_SATURATION,       // colour saturation; 1 = as sent
    CRT_DIAL_PEAK_HIGHLIGHTS,  // how far the tube's peaks may rise above reference white
                               //   (1 = SDR look); always capped by the panel's LIVE headroom
    // Phosphor pattern (colour tubes with a pattern other than triode)
    CRT_DIAL_PATTERN_SCALE,    // triad size in OUTPUT pixels; under ~3 the pattern merges to flat
    CRT_DIAL_PATTERN_FOCUS,    // 0 = softest/faintest .. 1 = tightest/purest; the engine derives
                               //   what that means per pattern
    // Glass and geometry
    CRT_DIAL_CURVATURE,        // faceplate curvature: 0 = flat, 1 = this tube's own radius, >1 exaggerated
    CRT_DIAL_HALATION,         // light returned by the glass (the broad halo); 0 = none
    CRT_DIAL_SCATTER,          // etched-face haze (the local glow); 0 = polished
    CRT_DIAL_OVERSCAN,         // raster size against the glass, fraction per side:
                               //   + overscan, 0 exact fit, - underscan
    CRT_DIAL_VIGNETTE,         // brightness falloff toward the edges
    // Beam
    CRT_DIAL_SHARPNESS,        // 0 = soft (beam fills the scanline cell) .. 1 = sharp
    CRT_DIAL_H_BANDWIDTH,      // video bandwidth, RC rolloff: lower = crisper (more ringing);
                               //   0 = ringless Gaussian spot, no anti-beat protection
    CRT_DIAL_H_FOCUS,          // bipolar focus pot, source px: 0 = focused, either way blurs
    CRT_DIAL_SHUTTER,          // observer: 1 = fused eye (steady) .. 0 = fast camera shutter
    CRT_DIAL_EDGE_FOCUS,       // focus lost toward the screen edges
    CRT_DIAL_BLOOM,            // beam widening with brightness
    CRT_DIAL_CONVERGENCE,      // bipolar: 0 = converged; sign = fringing direction
    // Signal and wear
    CRT_DIAL_H_JITTER,         // per-scanline horizontal shift
    CRT_DIAL_V_JITTER,         // per-frame vertical bounce, scanlines
    CRT_DIAL_SHOT_NOISE,       // per-pixel beam shot noise
    CRT_DIAL_SIGNAL_NOISE,     // additive snow
    CRT_DIAL_COUNT
} CRTDial;

// Number of dials the bridge implements. Must equal CRT_DIAL_COUNT.
int   crt_bridge_dial_count(void);
// The dial's travel. Returns false for an unknown dial.
bool  crt_bridge_dial_range(int dial, float *lo, float *hi);
// Where the dial is now: the user's position, or the preset's if untouched.
float crt_bridge_get_dial(CRTBridgeRef ref, int dial);
// Where the live preset starts the dial — what crt_bridge_reset_dial returns to.
float crt_bridge_dial_default(CRTBridgeRef ref, int dial);
// True when the user has moved the dial off the preset.
bool  crt_bridge_dial_is_set(CRTBridgeRef ref, int dial);
// Turn a dial (clamped to its range). Survives mode changes and preset switches.
void  crt_bridge_set_dial(CRTBridgeRef ref, int dial, float v);
// Put a dial back on the preset.
void  crt_bridge_reset_dial(CRTBridgeRef ref, int dial);

// --- Status -----------------------------------------------------------------

// One line saying what the tube is doing: the signal it is locked to, the lines and
// buffer the engine laid out for it, the picture's size on the panel and the panel's
// headroom. Writes NUL-terminated UTF-8 into `buffer`; returns the length written.
int crt_bridge_describe(CRTBridgeRef ref, char *buffer, int capacity);

// --- Per-frame ------------------------------------------------------------

// PRESENT ONE FRAME — run the CRT and put it on the drawable. The engine owns the
// whole display tail: the host must not scale, encode or aspect-fit the picture.
//
// `inputTexture` is the emulated frame, gamma-encoded as it left the card (a raw
// BGRA8 framebuffer is already right — do not linearise it). `time` is a monotonic
// seconds clock driving the beam sweep and phosphor decay. `target` is the drawable's
// id<MTLTexture>, `commandBuffer` an id<MTLCommandBuffer>.
//
// `sdrEncoded` describes the DRAWABLE — only the host knows this:
//   false = extended-linear float (rgba16Float + extendedLinear*) — engine writes
//           linear; the OS tonemaps above-white against the panel's EDR headroom.
//   true  = 8-bit gamma-encoded (bgra8Unorm + DisplayP3/sRGB) — engine soft-clips
//           above-white peaks and applies the BT.709 OETF.
// Writing linear into a gamma-encoded drawable reads DARK, and no brightness or
// contrast setting can correct it — it is a transfer-function mismatch.
//
// The picture is placed with the ENGINE's aspect-preserving viewport. Returns false
// on failure (the host then falls back to its raw feed).
bool crt_bridge_present(CRTBridgeRef ref, void *inputTexture, float time,
                        void *target, void *commandBuffer, bool sdrEncoded);

#ifdef __cplusplus
}
#endif

#endif // CRT_BRIDGE_H
