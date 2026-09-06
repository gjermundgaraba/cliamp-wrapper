#!/usr/bin/env bash
# Builds vendor/ghostty/macos/GhosttyKit.xcframework (the full libghostty
# embedder API: VT core, Metal renderer, PTY, input) from the Ghostty
# submodule. Zig caches everything, so re-running with no changes takes a
# few seconds. Ghostty main pins an exact Zig minor (build.zig.zon) and its
# build fails with a clear message on any other version.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GHOSTTY="$ROOT/vendor/ghostty"

if [ ! -f "$GHOSTTY/build.zig" ]; then
    echo "==> initialising vendor/ghostty submodule"
    git -C "$ROOT" submodule update --init --depth 1 vendor/ghostty
fi

if ! ZIG="$(command -v zig)"; then
    echo "error: zig not found. Install with: brew install zig" >&2
    exit 1
fi

if ! xcrun -sdk macosx metal --version >/dev/null 2>&1; then
    echo "error: Metal toolchain missing. Run: xcodebuild -downloadComponent MetalToolchain" >&2
    exit 1
fi

echo "==> zig $("$ZIG" version) building GhosttyKit.xcframework from ghostty $(git -C "$GHOSTTY" rev-parse --short HEAD)"
(
    cd "$GHOSTTY"
    "$ZIG" build -Doptimize=ReleaseFast -Demit-macos-app=false -Dxcframework-target=native
)
