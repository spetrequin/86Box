# 86Box + CRTBridge — boot rules for every session

This is a **fork** of 86Box carrying a local-only integration: a native Metal
renderer (`src/qt/qt_metalrenderer.mm`, `src/qt/metal_presenter.mm`) driving
CRTEngine through a C ABI. The engine is the sibling repo
`../../Swift/CRTEngine` — read its `CLAUDE.md` before touching anything that
reaches the simulation. **The engine decides the physics; 86Box is a host that
declares intent**, and specifically a *diagnostic* host: it exists to show the
engine real emulator output.

Layout: `crtbridge/` is the Swift package wrapping the **unmodified** engine
behind `crt_bridge.h`. It lives here, not in CRTEngine, because it is
integration glue. It uses only the engine's public API plus its resource
bundle — if a change seems to need editing CRTEngine, that is a conversation,
not a patch.

## Never build the bridge by hand

`crtbridge/build.sh` is the ONLY supported way. It produces the dylib and the
metallib **together, from one engine tree**, and CMake calls it as a single
step.

Why this is a rule and not a preference: the dylib statically links the
engine's Swift; the metallib is the engine's compiled shaders. Both read the
same `CRTUniforms` layout from the engine's `ShaderTypes.h`. Run `swift build`
alone and you refresh the dylib while leaving a stale metallib — Swift and GPU
then disagree on that struct, the engine fails, and **86Box silently drops to
its raw-feed fallback**. It looks like it works. It has cost real debugging
time. Do not split the two steps back apart.

There is no version pin on the engine, deliberately. A broken engine breaks
this build loudly (`set -e`), which is what a diagnostic host wants.

`-DCRTENGINE_DIR=/path` overrides the engine location. The default is derived
from the source tree (sibling-checkout layout, matching `Package.swift`'s own
fallback) — keep it that way; it was a hardcoded `$HOME` path once and only
ever configured on one machine.

## Build and verify

`./build-macos-metal.sh` — configures `build/macmetal`, builds, then `ditto`s
the app to `~/Applications/86Box.app`. Launch that copy; the build tree also
holds a `.app` and running the wrong one is how you "fix" a bug that was never
rebuilt.

**The signal that the CRT path actually engaged** is on stderr at renderer
init:

    [MetalRenderer] renderer initialized for monitor 0 (WxH), CRT=on

`CRT=stub` means the bridge did not engage and you are looking at the raw
framebuffer — treat any visual assessment made against `CRT=stub` as void.
Signal diagnostics land in `~/Library/Logs/86Box-crt-signal.log` (a
Finder-launched `.app` has no stderr).

Because the install is a `ditto` and not `cmake --install`, `INSTALL_RPATH`
never applies: the installed app keeps `BUILD_RPATH`, which lists
`crtbridge/.build/release` **before** `@executable_path/../Frameworks`. The
app therefore prefers the build-tree dylib over its own bundled copy. Fine on
this machine, but it means the installed app is not self-contained and a
wiped build tree changes which dylib loads.

## Traps that have already cost time here

- **Stale CMake cache, not a broken Homebrew.** A Homebrew upgrade leaves
  absolute Cellar paths in `build/macmetal/CMakeCache.txt`, and configure dies
  with `Imported target "PkgConfig::SNDFILE" includes non-existent path
  .../mpg123/<old>/include`. Check `pkg-config --cflags sndfile` first — if it
  resolves clean, the disk is fine. Fix: `rm build/macmetal/CMakeCache.txt`.
  Do NOT `brew reinstall` to chase it.
- **`crtbundle` never cleans.** It copies into `Contents/Frameworks` and
  `Contents/Resources` and removes nothing, so anything hand-dropped there
  (e.g. a `libCRTBridgeC.dylib.bak-*`) persists into every future build and
  ships inside the app. Check that directory before believing it is clean.
- **Two `.metal` files in the engine are not in its `resources:` list**
  (`AWBCompute`, `RFNoiseInjection`), and the engine also carries a checked-in
  `Resources/default.metallib` SwiftPM reports as unhandled. `build-metallib.sh`
  globs `Shaders/*.metal`, so the metallib it builds is complete regardless —
  do not "fix" this by trusting the engine's resource manifest instead.

## Git

`origin` is the **public upstream** `86Box/86Box` — never push there. Push to
`fork` (`spetrequin/86Box`). Branch always; this integration is local-only and
cannot build for anyone without CRTEngine, so it is not upstream-PR material
as it stands.

Keep the artifacts true in the same commit: the comments in
`src/qt/CMakeLists.txt` around the `crtbridge` target carry the *reasons* for
the one-step build, and this file carries the rest. A change that invalidates
either is not done until both are updated.
