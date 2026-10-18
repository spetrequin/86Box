#!/bin/bash
# Compile CRTEngine's Metal shaders into a default.metallib, reading the engine
# sources READ-ONLY and writing only to the given output path — so CRTEngine's
# tree is never modified. (CRTEngine ships its own compile-shaders.sh, but that
# writes into its Resources dir; we keep the engine pristine.)
#
# Usage: build-metallib.sh <CRTEngine-dir> <output-metallib-path>
set -euo pipefail

ENGINE="$1"
OUT="$2"
SHADER_DIR="$ENGINE/Sources/CRTEngine/Shaders"
BRIDGE_INCLUDE="$ENGINE/Sources/CRTEngineBridge/include"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

AIR=()
for METAL in "$SHADER_DIR"/*.metal; do
    B="$(basename "$METAL" .metal)"
    A="$TMP/$B.air"
    xcrun -sdk macosx metal -c "$METAL" -o "$A" \
        -I "$BRIDGE_INCLUDE" -I "$SHADER_DIR" \
        -std=metal3.0 -isysroot "$SDK"
    AIR+=("$A")
done

mkdir -p "$(dirname "$OUT")"
xcrun -sdk macosx metallib "${AIR[@]}" -o "$OUT"
echo "metallib -> $OUT"
