#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$PROJECT_DIR/.build/swiftpm-cache"
CHECK_PACKAGE="$PROJECT_DIR/.build/math-transcript-ui-package"
python3 - "$PROJECT_DIR" <<'PY'
import pathlib
import shutil
import sys

root = pathlib.Path(sys.argv[1])
package = root / ".build/math-transcript-ui-package"
sources = package / "Sources"
shutil.rmtree(sources, ignore_errors=True)
shutil.copytree(root / "Sources/FloatingAICore", sources / "FloatingAICore")
app = sources / "MathTranscriptChecks"
app.mkdir(parents=True)
for source in (root / "Sources/FloatingAI").glob("*.swift"):
    if source.name not in ("AppMain.swift", "PreviewRenderer.swift"):
        shutil.copy2(source, app / source.name)
shutil.copy2(root / "Checks/MathTranscriptUI/main.swift", app / "CheckRunner.swift")
manifest = '''// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "MathTranscriptChecks", platforms: [.macOS(.v13)], targets: [
    .target(name: "FloatingAICore"),
    .executableTarget(name: "MathTranscriptChecks", dependencies: ["FloatingAICore"])
])
'''
manifest_path = package / "Package.swift"
if not manifest_path.exists() or manifest_path.read_text() != manifest:
    manifest_path.write_text(manifest)
PY
swift build --disable-sandbox --package-path "$CHECK_PACKAGE" --cache-path "$PROJECT_DIR/.build/swiftpm-cache" --product MathTranscriptChecks
BIN_DIR="$(swift build --disable-sandbox --package-path "$CHECK_PACKAGE" --show-bin-path)"
mkdir -p "$BIN_DIR/MathRendering"
cp -RX "$PROJECT_DIR/Resources/MathRendering/." "$BIN_DIR/MathRendering"
"$BIN_DIR/MathTranscriptChecks"
