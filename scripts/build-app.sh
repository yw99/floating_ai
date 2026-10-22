#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$PROJECT_DIR/Floating AI.app"
BUILD_ARCH="${1:-native}"
cd "$PROJECT_DIR"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$PROJECT_DIR/.build/swiftpm-cache"

case "$BUILD_ARCH" in
  native)
    swift build --disable-sandbox --configuration release --product FloatingAI --cache-path "$PROJECT_DIR/.build/swiftpm-cache"
    swift build --disable-sandbox --configuration release --product FloatingAIFileTool --cache-path "$PROJECT_DIR/.build/swiftpm-cache"
    BIN_DIR="$(swift build --disable-sandbox --configuration release --cache-path "$PROJECT_DIR/.build/swiftpm-cache" --show-bin-path)"
    APP_BINARY="$BIN_DIR/FloatingAI"
    FILE_TOOL="$BIN_DIR/FloatingAIFileTool"
    ;;
  universal)
    "$PROJECT_DIR/scripts/verify-architectures.sh"
    APP_BINARY="$PROJECT_DIR/.build/universal/FloatingAI"
    FILE_TOOL="$PROJECT_DIR/.build/universal/FloatingAIFileTool"
    ;;
  *)
    printf 'Usage: %s [native|universal]\n' "$0" >&2
    exit 2
    ;;
esac

# Desktop/iCloud File Provider adds FinderInfo to .app folders asynchronously.
# Sign and archive outside that provider so the distributable stays reproducible.
STAGING_DIR="$(mktemp -d /private/tmp/floatingai-build.XXXXXX)"
trap 'rm -rf "$STAGING_DIR"' EXIT
STAGED_PACKAGE="$STAGING_DIR/package"
STAGED_APP="$STAGED_PACKAGE/Floating AI.app"
ZIP_NAME="Floating-AI-macOS-$BUILD_ARCH.zip"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp -X "$APP_BINARY" "$STAGED_APP/Contents/MacOS/FloatingAI"
cp -X "$FILE_TOOL" "$STAGED_APP/Contents/MacOS/FloatingAIFileTool"
cp -X "$PROJECT_DIR/Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
cp -RX "$PROJECT_DIR/Resources/MathRendering" "$STAGED_APP/Contents/Resources/MathRendering"
chmod +x "$STAGED_APP/Contents/MacOS/FloatingAI"
chmod +x "$STAGED_APP/Contents/MacOS/FloatingAIFileTool"
/usr/bin/plutil -lint "$STAGED_APP/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$STAGED_APP/Contents/MacOS/FloatingAIFileTool"
/usr/bin/codesign --force --sign - "$STAGED_APP"
/usr/bin/codesign --verify --strict "$STAGED_APP"
cp -X "$PROJECT_DIR/floating_ai" "$STAGED_PACKAGE/floating_ai"
chmod +x "$STAGED_PACKAGE/floating_ai"
/usr/bin/ditto -c -k --sequesterRsrc "$STAGED_PACKAGE" "$STAGING_DIR/$ZIP_NAME"

mkdir -p "$PROJECT_DIR/dist"
rm -rf "$APP_DIR"
/usr/bin/ditto --noextattr --norsrc "$STAGED_APP" "$APP_DIR"
cp -X "$STAGING_DIR/$ZIP_NAME" "$PROJECT_DIR/dist/$ZIP_NAME"
/usr/bin/xattr -d com.apple.FinderInfo "$APP_DIR" 2>/dev/null || true
printf 'Built: %s\nArchive: %s\n' "$APP_DIR" "$PROJECT_DIR/dist/$ZIP_NAME"

