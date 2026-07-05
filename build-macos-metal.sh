#!/bin/bash
# Configure + build 86Box on macOS (Apple Silicon) against Homebrew Qt6,
# with the native Metal CRT renderer (RENDERER_METAL) compiled in.
# Stub stage: presents the framebuffer straight (no CRTEngine yet).
set -euo pipefail
cd "$(dirname "$0")"

BUILD_DIR=build/macmetal
QT_PREFIX="$(brew --prefix qt)"

cmake -S . -B "$BUILD_DIR" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE=cmake/llvm-macos-aarch64.cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DQT=ON -DUSE_QT6=ON -DNEW_DYNAREC=ON \
    -DCMAKE_PREFIX_PATH="$QT_PREFIX" \
    -DMOLTENVK_DIR="$(brew --prefix molten-vk)" \
    -DOpenAL_ROOT="$(brew --prefix openal-soft)" \
    -DLIBSERIALPORT_ROOT="$(brew --prefix libserialport)"

cmake --build "$BUILD_DIR"

# Install into ~/Applications so the app you launch is always the one just built.
# (The build output lives under build/; launching from ~/Applications would
# otherwise silently run a stale copy.)
BUILT_APP="$BUILD_DIR/src/86Box.app"
INSTALL_APP="$HOME/Applications/86Box.app"
if [ -d "$BUILT_APP" ]; then
    rm -rf "$INSTALL_APP"
    ditto "$BUILT_APP" "$INSTALL_APP"
    echo "=== installed: $INSTALL_APP ==="
    stat -f '=== binary build time: %Sm ===' -t '%Y-%m-%d %H:%M:%S' \
        "$INSTALL_APP/Contents/MacOS/86Box"
fi
echo "=== built: $BUILT_APP ==="
