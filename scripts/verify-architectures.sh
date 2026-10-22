#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"
cd "$PROJECT_DIR"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$PROJECT_DIR/.build/swiftpm-cache"

for BUILD_ARCH in arm64 x86_64; do
  swift build --disable-sandbox --configuration release --product FloatingAI \
    --cache-path "$PROJECT_DIR/.build/swiftpm-cache" \
    --triple "$BUILD_ARCH-apple-macosx13.0" \
    --sdk "$MACOS_SDK" \
    --scratch-path "$PROJECT_DIR/.build/$BUILD_ARCH-check"
  swift build --disable-sandbox --configuration release --product FloatingAIFileTool \
    --cache-path "$PROJECT_DIR/.build/swiftpm-cache" \
    --triple "$BUILD_ARCH-apple-macosx13.0" \
    --sdk "$MACOS_SDK" \
    --scratch-path "$PROJECT_DIR/.build/$BUILD_ARCH-check"
done

ARM_BIN_DIR="$(swift build --disable-sandbox --configuration release --triple arm64-apple-macosx13.0 --sdk "$MACOS_SDK" --scratch-path "$PROJECT_DIR/.build/arm64-check" --show-bin-path)"
INTEL_BIN_DIR="$(swift build --disable-sandbox --configuration release --triple x86_64-apple-macosx13.0 --sdk "$MACOS_SDK" --scratch-path "$PROJECT_DIR/.build/x86_64-check" --show-bin-path)"

mkdir -p "$PROJECT_DIR/.build/universal"
xcrun lipo -create \
  "$ARM_BIN_DIR/FloatingAI" \
  "$INTEL_BIN_DIR/FloatingAI" \
  -output "$PROJECT_DIR/.build/universal/FloatingAI"
xcrun lipo "$PROJECT_DIR/.build/universal/FloatingAI" -verify_arch arm64 x86_64
xcrun lipo -info "$PROJECT_DIR/.build/universal/FloatingAI"
xcrun lipo -create "$ARM_BIN_DIR/FloatingAIFileTool" "$INTEL_BIN_DIR/FloatingAIFileTool" -output "$PROJECT_DIR/.build/universal/FloatingAIFileTool"
xcrun lipo "$PROJECT_DIR/.build/universal/FloatingAIFileTool" -verify_arch arm64 x86_64
xcrun lipo -info "$PROJECT_DIR/.build/universal/FloatingAIFileTool"
