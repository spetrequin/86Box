#!/bin/bash
# build.sh — build the CRTBridge dylib AND compile CRTEngine's shaders into the
# bundle's metallib, in ONE step, from whatever CRTEngine is checked out.
#
# WHY ONE SCRIPT: the dylib statically links the engine's Swift; the metallib is
# the engine's compiled Metal shaders. Both read the SAME shared C struct layout
# (CRTUniforms, in CRTEngine's ShaderTypes.h). If you build them separately and
# the engine has moved, they disagree on that layout — the engine then fails and
# 86Box silently drops to its raw-feed fallback. Building them together, always
# from the same engine tree, makes that desync impossible. Do NOT run
# `swift build` by hand and copy just the dylib — run this.
#
# 86Box is a diagnostic host and tracks the engine tip on purpose: there is no
# version pin. If the engine's shaders don't compile, this fails (set -e) and the
# 86Box build stops — a broken engine breaks the build, loudly, by design.
#
# Usage:  [CRTENGINE_DIR=/path/to/CRTEngine] ./build.sh
#         CRTENGINE_DIR selects the engine (CMake passes it). Without it, falls
#         back to the sibling checkout, matching Package.swift.
set -euo pipefail
cd "$(dirname "$0")"

# Default matches Package.swift's crtEnginePath (…/Code/Swift/CRTEngine relative
# to …/Code/C/86Box/crtbridge). Resolve to an absolute path so swift build and
# build-metallib.sh agree on the same engine.
ENGINE_REL="${CRTENGINE_DIR:-../../../Swift/CRTEngine}"
ENGINE="$(cd "$ENGINE_REL" && pwd)"

echo "=== CRTBridge: building against CRTEngine at $ENGINE ==="

# 1) dylib — SwiftPM relinks the current engine's Swift (it tracks the path
#    dependency's sources, so this picks up engine changes automatically).
CRTENGINE_DIR="$ENGINE" swift build -c release --product CRTBridgeC

# 2) metallib — compile the current engine's shaders INTO the just-built bundle,
#    overwriting whatever swift build may have copied from the engine's Resources
#    (that copy can be a stale, separately-generated artifact). This is the step a
#    hand-run `swift build` skips, which is how the metallib went stale before.
BUNDLE=".build/release/CRTEngine_CRTEngine.bundle"
# Insist the bundle already exists. build-metallib.sh does `mkdir -p` on its
# output dir, so without this check a missing bundle (engine dropped its
# `resources:` declaration, SwiftPM renamed it) would be *created* here holding
# only the metallib. build.sh would exit 0, CMake would copy that shell into
# 86Box.app, and Bundle.module would fail at runtime looking for CRTPresets.json
# — the silent fallback this script exists to prevent.
[ -d "$BUNDLE" ] || { echo "ERROR: $BUNDLE missing — swift build produced no resource bundle" >&2; exit 1; }
./build-metallib.sh "$ENGINE" "$BUNDLE/default.metallib"

echo "=== CRTBridge: dylib + metallib built together from $ENGINE ==="
