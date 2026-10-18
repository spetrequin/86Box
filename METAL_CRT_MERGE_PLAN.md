# Merge plan — wire CRTEngine into the 86Box Metal renderer

Goal: replace the stub's straight-present (`metal_presenter.mm::present()`) with
the CRTEngine simulation, driven through the proven C bridge
(`~/Projects/Code/Swift/CRTBridgeProbe`), and make it build/link/ship inside
86Box's CMake + `.app` bundle.

Both unknowns are already retired: the Swift↔C++ bridge works
(`CRTBridgeProbe`), and the Metal presentation seam works (`../metalprobe`).
What's left is **plumbing**: a linkable Swift artifact, the resource bundle,
build-time shader compilation, and a stateful render cadence.

The plan is 6 phases. Each ends at a state that builds and runs, so you can stop
and verify between them.

---

## Phase 0 — Promote the bridge to a shippable product   ✅ DONE

Today `CRTBridge` lives in the throwaway `CRTBridgeProbe` package. Fold it into
CRTEngine so one `swift build` produces engine + bridge + resources together and
they version in lockstep.

**`~/Projects/Code/Swift/CRTEngine/Package.swift`** — add a C-ABI product:
```swift
products: [
    .library(name: "CRTEngine", targets: ["CRTEngine"]),
    .library(name: "CRTBridgeC", type: .dynamic, targets: ["CRTBridgeC"]),  // NEW: dylib w/ C symbols
],
targets: [
    ... existing ...
    .target(name: "CRTBridgeC", dependencies: ["CRTEngine"], path: "Sources/CRTBridgeC"),
]
```

**`~/Projects/Code/Swift/CRTEngine/Sources/CRTBridgeC/CRTBridge.swift`** — move
`CRTBridgeProbe/Sources/CRTBridge/CRTBridge.swift` here verbatim, then extend it
(Phase 1). Building `type: .dynamic` yields `libCRTBridgeC.dylib` whose only
exported C symbols are the `@_cdecl` ones; it links the Swift runtime via rpath
to the OS `/usr/lib/swift` (ABI-stable, ships with macOS 12+), so **CMake treats
it as an ordinary dylib** — no Swift toolchain knowledge needed downstream.

**`~/Projects/Code/Swift/CRTEngine/Sources/CRTBridgeC/include/crt_bridge.h`** —
move the header here (copy of `CRTBridgeProbe/.../crt_bridge.h`). This is the
header 86Box compiles against.

Keep `CRTBridgeProbe` as the smoke test (point its dependency at the new product).

*Verify:* `swift build -c release` in CRTEngine produces
`.build/release/libCRTBridgeC.dylib` and `CRTEngine_CRTEngine.bundle`.

---

> **Status:** Phase 0 done — `CRTBridgeC` dynamic product added to CRTEngine's
> `Package.swift`; bridge moved to `Sources/CRTBridgeC/{CRTBridge.swift,
> include/crt_bridge.h}`. `swift build -c release --product CRTBridgeC` →
> `.build/release/libCRTBridgeC.dylib`, exporting unmangled `_crt_bridge_*`
> symbols, Swift runtime via `/usr/lib/swift` rpath.

## Phase 1 — Bridge API additions (resource injection + dynamic state)   ✅ DONE

`Bundle.module` is unreliable once the dylib is relocated into a `.app`. Add
explicit-path creation and the per-frame state 86Box needs. **Two small
CRTEngine changes** unblock path injection:

**`Sources/CRTEngine/Utilities/MetalLibrary.swift`** — *(DONE — implemented as an
injectable override instead of an init param, because `makeLibrary(device:)` has
**22 call sites**; one override covers them all, vs. threading a URL through every
pipeline factory)*:
```swift
nonisolated(unsafe) public static var overrideURL: URL?   // set before first CRTFilter
// makeLibrary(device:) now returns makeLibrary(url: overrideURL) when set, else Bundle.module.
public static func makeLibrary(device: MTLDevice, url: URL) throws -> MTLLibrary { ... }
```
The bridge's `create2` sets `CRTEngineLibrary.overrideURL` before constructing the
filter. **`CRTFilter.init` was NOT touched** — the override supersedes the planned
`libraryURL:` param. (`PresetLoader.loadPresetsFromFile(url:)` already public.)

**`Sources/CRTBridgeC/CRTBridge.swift`** — new/changed entry points:
| Symbol | Purpose |
|---|---|
| `crt_bridge_create2(void* device, int w, int h, const char* metallibPath)` | Like `create`, but builds `CRTFilter` from an explicit metallib URL (bypasses `Bundle.module`). Requires threading the URL into `CRTFilter` init — see note below. |
| `crt_bridge_apply_preset_file(ref, const char* presetsJsonPath, const char* presetName, int cw, int ch)` | Load presets from an explicit JSON path via `PresetLoader.loadPresetsFromFile`. |
| `crt_bridge_set_content_size(ref, int cw, int ch)` | Light reconfigure on 86Box mode change without re-reading presets (re-applies preset with new `contentSize`, recomputes layout). |
| `crt_bridge_set_display_refresh(ref, float hz)` | Set `filter.displayRefreshRate` for correct field cadence. |

> Note: `CRTFilter.init` currently calls `CRTEngineLibrary.makeLibrary(device:)`
> internally (Bundle.module). To honor an injected metallib path cleanly, add an
> optional `libraryURL: URL?` param to `CRTFilter.init` (defaulting to nil →
> current behavior). Small, backward-compatible CRTEngine change. If you'd
> rather not touch `CRTFilter.init`, fall back to **Phase 2's bundle-copy**
> approach and keep using `Bundle.module` — then Phase 1 only needs
> `set_content_size` + `set_display_refresh`.

*Verify:* **DONE** — `~/Projects/Code/C/bridgelinktest/` links a clang++ Obj-C++
TU directly against `libCRTBridgeC.dylib` (no SwiftPM) and drives the path-based
API: `create2(metallib)` + `apply_preset_file(json, "VGA monitor")` +
`set_content_size` (mode-change) + 90 render frames. Output is identical to the
SwiftPM probe (1600×1200 rgba16Float, byte-sum 863518716). Rebuild/run:
```sh
cd ~/Projects/Code/Swift/CRTEngine && swift build -c release --product CRTBridgeC
cd ~/Projects/Code/C/bridgelinktest && clang++ -std=c++17 -fobjc-arc main.mm \
  -I ~/Projects/Code/Swift/CRTEngine/Sources/CRTBridgeC/include \
  -L ~/Projects/Code/Swift/CRTEngine/.build/release -lCRTBridgeC \
  -framework Metal -framework Foundation \
  -Wl,-rpath,~/Projects/Code/Swift/CRTEngine/.build/release -Wl,-rpath,/usr/lib/swift \
  -o bridgelinktest && ./bridgelinktest \
  ~/Projects/Code/Swift/CRTEngine/Sources/CRTEngine/Resources/{default.metallib,CRTPresets.json}
```

> New bridge symbols added: `crt_bridge_create2`, `crt_bridge_apply_preset_file`,
> `crt_bridge_set_content_size`, `crt_bridge_set_display_refresh` (plus the
> originals). Header: `CRTEngine/Sources/CRTBridgeC/include/crt_bridge.h`.

---

## Phase 2 — CMake: build, link, bundle   ← NEXT

**`src/qt/CMakeLists.txt`** (inside the existing `if(APPLE)` block I added):

1. **Locate the engine checkout** (option, default to the sibling path):
   ```cmake
   set(CRTENGINE_DIR "$ENV{HOME}/Projects/Code/Swift/CRTEngine" CACHE PATH "CRTEngine source")
   ```

2. **Build the Swift bridge at configure/build time** via `add_custom_command`
   driving `swift build -c release`, output `libCRTBridgeC.dylib`:
   ```cmake
   set(CRTBRIDGE_DYLIB ${CRTENGINE_DIR}/.build/release/libCRTBridgeC.dylib)
   set(CRTENGINE_BUNDLE ${CRTENGINE_DIR}/.build/release/CRTEngine_CRTEngine.bundle)
   add_custom_command(OUTPUT ${CRTBRIDGE_DYLIB}
       COMMAND swift build -c release --product CRTBridgeC
       WORKING_DIRECTORY ${CRTENGINE_DIR}
       COMMENT "Building CRTEngine Swift bridge")
   add_custom_target(crtbridge DEPENDS ${CRTBRIDGE_DYLIB})
   add_dependencies(ui crtbridge)
   ```

3. **Compile shaders → metallib** (CLI swift build does NOT — see CRTBridgeProbe
   FINDINGS). Reuse the engine's script:
   ```cmake
   add_custom_command(TARGET crtbridge POST_BUILD
       COMMAND ${CRTENGINE_DIR}/compile-shaders.sh
       COMMENT "Compiling CRTEngine Metal shaders -> default.metallib")
   ```
   (Writes `Resources/default.metallib`; copy it next to the JSON in step 5.)

4. **Link + include:**
   ```cmake
   target_include_directories(ui PRIVATE ${CRTENGINE_DIR}/Sources/CRTBridgeC/include)
   target_link_libraries(ui PRIVATE ${CRTBRIDGE_DYLIB})
   target_compile_definitions(ui PRIVATE USE_CRTENGINE)
   ```

5. **Ship into the `.app`** (extend the existing `if (APPLE AND
   CMAKE_MACOSX_BUNDLE)` block near line 507 that already bundles MoltenVK):
   - copy `libCRTBridgeC.dylib` → `Contents/Frameworks/`, fix its install name
     + add rpath `@executable_path/../Frameworks` (mirror
     `install_bundle_library(...)` used for MoltenVK).
   - copy `CRTPresets.json` + `default.metallib` → a known Resources subdir,
     e.g. `Contents/Resources/CRTEngine/`. These paths feed
     `crt_bridge_*_file` / `crt_bridge_create2`.

*Verify:* `cmake --build` links 86Box with the dylib; `otool -L 86Box.app/.../86Box`
shows `@rpath/libCRTBridgeC.dylib`; the Resources dir holds the JSON + metallib.

---

## Phase 3 — `metal_presenter`: insert the engine at the seam

**`src/qt/metal_presenter.h`** — additions:
```cpp
// after init():
bool   enableCRT(const char* presetsJsonPath, const char* metallibPath,
                 const char* presetName, int contentW, int contentH);
void   setContentSize(int contentW, int contentH);   // 86Box mode change
void   setDisplayRefresh(float hz);
// present() gains a time arg for the phosphor clock:
void   present(int srcX, int srcY, int srcW, int srcH, float timeSeconds);
```

**`src/qt/metal_presenter.mm`** — wire the bridge (`#ifdef USE_CRTENGINE`):
```objcpp
#include "crt_bridge.h"
// Impl gains: CRTBridgeRef crt = nullptr; bool crtOn = false; int cw, ch;
```
- `enableCRT(...)`: `crt = crt_bridge_create2(impl->device, kSrcDim, kSrcDim, metallibPath);`
  then `crt_bridge_apply_preset_file(crt, presetsJsonPath, presetName, cw, ch);`
  Set `impl->layer.pixelFormat = MTLPixelFormatRGBA16Float;`
  `impl->layer.wantsExtendedDynamicRangeContent = YES;`
  `impl->layer.colorspace = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearDisplayP3);`
  Rebuild the present pipeline's color attachment to `RGBA16Float`. Set `crtOn`.
- `setContentSize` → `crt_bridge_set_content_size(crt, cw, ch)`.
- `present(...,time)`: when `crtOn`,
  ```objcpp
  id<MTLCommandBuffer> cb = [impl->queue commandBuffer];
  void* outPtr = crt_bridge_render(crt, (__bridge void*)impl->source, time, (__bridge void*)cb);
  id<MTLTexture> crtTex = (__bridge id<MTLTexture>)outPtr;
  // draw crtTex (instead of impl->source) into drawable.texture on the SAME cb
  id<CAMetalDrawable> d = [impl->layer nextDrawable];
  drawTexture(impl, d.texture, crtTex, cb);   // generalize drawInto to take a source tex
  [cb presentDrawable:d]; [cb commit];
  ```
  Generalize the existing `drawInto` to accept the source `id<MTLTexture>` so it
  serves both the stub (`impl->source`) and CRT (`crtTex`) paths.
- destructor: `if (crt) crt_bridge_destroy(crt);`

*Verify:* the `../metalprobe` harness gains an `enableCRT` path (point it at the
built JSON + metallib) and asserts the output is non-empty rgba16Float — same
proof as CRTBridgeProbe, now through the presenter.

---

## Phase 4 — `qt_metalrenderer`: decouple cadence (the real design point)

The phosphor sim is **stateful and real-time**: decay continues *between*
emulator frames, so it must redraw at display rate, not only on blit. Mirror
Phosphors' split (content updates at content rate, render at display rate).

**`src/qt/qt_metalrenderer.hpp`** — add:
```cpp
#include <QTimer>          // or CVDisplayLink for vsync-accurate cadence
QTimer*  renderTimer = nullptr;
double   t0 = 0.0;         // monotonic origin
int      lastContentW = 0, lastContentH = 0;
```

**`src/qt/qt_metalrenderer.mm`** — changes:
- `onBlit(buf_idx,x,y,w,h)`: **upload only**, then handle mode changes:
  ```cpp
  presenter->upload(imagebufs[buf_idx].get(), x, y, w, h, getBytesPerRow());
  buf_usage[buf_idx ^ 1].clear();
  source.setRect(x, y, w, h);
  int cw = monitors[r_monitor_index].mon_unscaled_size_x;   // or track w/h extents
  int ch = monitors[r_monitor_index].mon_unscaled_size_y;
  if (cw != lastContentW || ch != lastContentH) { presenter->setContentSize(cw, ch); lastContentW=cw; lastContentH=ch; }
  // NOTE: no present() here anymore
  ```
- `initialize()`: after `presenter->init`, call
  `presenter->enableCRT(presetsPath, metallibPath, "VGA monitor", cw, ch)` (paths
  from `QCoreApplication::applicationDirPath()` + `/../Resources/CRTEngine/...`),
  `presenter->setDisplayRefresh(screen()->refreshRate())`, then start a timer at
  the display refresh:
  ```cpp
  renderTimer = new QTimer(this);
  connect(renderTimer, &QTimer::timeout, this, [this]{
      presenter->present(source.x(), source.y(), source.width(), source.height(),
                         float(elapsedSeconds()));   // CFAbsoluteTime - t0
  });
  renderTimer->start(0);   // or drive from CVDisplayLink
  ```
- `finalize()`: `renderTimer->stop();`

> Multi-monitor: each `RendererStack`/`MetalRenderer` is per-monitor with its own
> `r_monitor_index`; the bridge handle is per-presenter, so this is already
> isolated. Just confirm `MONITORS_NUM` instances don't oversubscribe the GPU
> (one CRTFilter each is fine).

*Verify:* run 86Box, select **Video → Renderer → Metal (CRT)**, boot a PC; a
DOS text screen and VGA graphics should show phosphor/beam/mask. Toggle to a
mode switch (text↔graphics) and confirm no crash + correct re-layout.

---

## Phase 5 — Options dialog + persistence (polish, optional for v1)

**`src/qt/qt_metalrenderer.{hpp,mm}`** — implement `hasOptions()/getOptions()`
(RendererCommon hooks) to expose a preset picker ("VGA monitor", "Green CRT
monitor", "Amber CRT monitor", "NTSC color", …) and aging/sharpness sliders that
call new `crt_bridge_set_*` setters. Persist the choice via 86Box's config
(`config.c` / a `vid_*` int) so it survives restart. This is the host-owns-UI /
engine-owns-physics split CRTEngine is designed around.

---

## Risk register

| Risk | Mitigation |
|---|---|
| Swift runtime not found at load | Target macOS 12+ (runtime in `/usr/lib/swift`); else bundle `swift-*.dylib`. `otool -L` + `DYLD_PRINT_LIBRARIES` to debug. |
| `Bundle.module` can't find resources in `.app` | Phase 1 path-injection (`*_file` / `create2`) avoids it entirely. Bundle-copy is the fallback. |
| Engine output is `rgba16Float`/EDR; layer was BGRA8 | Phase 3 switches layer format + rebuilds pipeline color attachment. |
| Phosphor decay frozen between blits | Phase 4 display-rate timer is the fix; do not present from `onBlit`. |
| Mode-change churn (re-applyPreset every blit) | Guard on content-size change (Phase 4) so it only fires on actual mode switches. |
| `swift build` slows CMake every run | `add_custom_command` keys on the dylib output; only rebuilds when Swift sources change. |
| ARC/ownership across the boundary | Bridge already uses `Unmanaged` (retained handle, unretained borrowed textures); validated in CRTBridgeProbe. |

## Build-order summary

```
swift build -c release (libCRTBridgeC.dylib + bundle)   ← Phase 0/2
   └─ compile-shaders.sh (default.metallib)              ← Phase 2
        └─ cmake build 86Box (links dylib, bundles res)  ← Phase 2
             └─ run: Video ▸ Renderer ▸ Metal (CRT)      ← Phase 4
```

## Touched files at a glance

**CRTEngine (Swift):**
- `Package.swift` — new `CRTBridgeC` dynamic product (Phase 0)
- `Sources/CRTBridgeC/CRTBridge.swift` + `include/crt_bridge.h` — bridge (moved + extended)
- `Sources/CRTEngine/Utilities/MetalLibrary.swift` — `makeLibrary(device:url:)` (Phase 1)
- `Sources/CRTEngine/CRT/CRTFilter.swift` — optional `libraryURL:` init param (Phase 1, optional)

**86Box (C++/Obj-C++):**
- `src/qt/CMakeLists.txt` — build/link/bundle the dylib + resources (Phase 2)
- `src/qt/metal_presenter.h` / `.mm` — `enableCRT`/`setContentSize`/timed `present`; engine at the seam (Phase 3)
- `src/qt/qt_metalrenderer.hpp` / `.mm` — render-cadence timer, mode-change detection, enableCRT wiring (Phase 4)
- `src/qt/qt_metalrenderer.{hpp,mm}` + `config.c` — options dialog + persistence (Phase 5, optional)

No emulator-core files change. Everything outside `src/qt/` (and the one
renderdefs.h line already added) is untouched.
```
