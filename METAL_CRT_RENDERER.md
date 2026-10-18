# Metal CRT renderer — stub

A native Metal renderer backend (`RENDERER_METAL`, Apple-only), added as the
landing site for the CRTEngine CRT simulation. **This stub presents the
emulated framebuffer straight to screen** (scaled, no CRT effect yet) — its job
is to prove the renderer registration + `CAMetalLayer` presentation seam before
the CRT engine is wired in.

## Files added

| File | Role |
|---|---|
| `src/qt/metal_presenter.h` / `.mm` | Framework-agnostic Metal core: owns the `MTLDevice`, a `CAMetalLayer`, a 2048-wide source texture matching 86Box's blit buffer, and a tiny scale-to-drawable pipeline. **No Qt** — so it's unit-testable standalone. |
| `src/qt/qt_metalrenderer.hpp` / `.mm` | `QWindow`+`RendererCommon` shell, embedded via `createWindowContainer` exactly like the OpenGL/Vulkan window renderers. Attaches a `CAMetalLayer` to its NSView and drives `MetalPresenter` from `onBlit`. |

## Wiring (mirrors the Vulkan renderer everywhere)

- `src/include/86box/renderdefs.h` — `RENDERER_METAL 4`, `RENDERER_NAME_QT_METAL`.
- `src/qt/qt_rendererstack.hpp` — `Renderer::Metal = 4` (explicit, so the
  existing `(RendererStack::Renderer) vid_api` casts keep working; 3 stays VNC).
- `src/qt/qt_rendererstack.cpp` — `#ifdef Q_OS_MACOS` include + `case
  Renderer::Metal` in `createRenderer` (HW pattern: buffers fetched on the
  `rendererInitialized` signal, software fallback on `errorInitializing`), and
  the buffer-deferral tail excludes Metal.
- `src/qt/qt_mainwindow.cpp` — `RENDERER_METAL` case in the `vid_api` switch +
  `actionMetal` added to the renderer `QActionGroup` (hidden off-Apple).
- `src/qt/qt_mainwindow.ui` — `actionMetal` ("&Metal (CRT)", `vid_api` = 4).
- `src/qt/CMakeLists.txt` — sources added under `if(APPLE)`, links
  `Metal` / `QuartzCore` / `AppKit`.

## Per-frame flow

```
emulator blit thread → RendererStack::blit → copies target_buffer into a
shared CPU double-buffer → emit blitToRenderer (QueuedConnection, UI thread)
→ MetalRenderer::onBlit → MetalPresenter::upload (CPU→MTLTexture, BGRA8)
→ MetalPresenter::present (scale source rect → CAMetalLayer drawable)
```

86Box's framebuffer is ARGB32 (`0x00RRGGBB`); the source texture is
`BGRA8Unorm`, which reads those little-endian bytes (`B,G,R,X`) correctly — same
trick the OpenGL renderer uses (`glTexSubImage2D(..., BGRA, UInt32_RGBA8_Rev)`).

## Verified

`metal_presenter.mm` compiles and runs outside 86Box (no Qt needed). The probe
at `../metalprobe/` uploads color bars through the real presenter pipeline and
reads them back: **8/8 bars reproduced with correct colors**, `present()` runs
clean. Build + run:

```sh
cd ../metalprobe && ./build.sh && ./metalprobe
```

A full 86Box build (Qt6 via vcpkg) was **not** run here — Qt6 isn't installed.
The Qt-facing code follows the existing renderer contracts exactly; it needs a
real 86Box build to link-verify.

## Next: insert CRTEngine

The seam is marked in `metal_presenter.mm::present()`. To light up the CRT sim:

1. Build the Swift `CRTBridge` (see `~/Projects/Code/Swift/CRTBridgeProbe`) as a
   static lib/xcframework; link it + the Swift runtime into the `ui` target.
2. In `MetalPresenter::init`, also `crt_bridge_create(device, ...)` and
   `crt_bridge_apply_preset("VGA monitor", contentW, contentH)`.
3. In `present()`, replace "draw `impl->source` straight" with: feed
   `impl->source` to `crt_bridge_render(...)` on the command buffer and draw the
   returned texture. Engine output is `rgba16Float` → switch the layer to
   `MTLPixelFormatRGBA16Float` + EDR.
4. Re-`apply_preset` when 86Box changes video mode (`mon_xsize/mon_ysize`).
5. CMake: compile CRTEngine's `Shaders/*.metal` → `default.metallib` and bundle
   it (CLI builds don't do this automatically — see CRTBridgeProbe FINDINGS).
```
