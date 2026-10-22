#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$PROJECT_DIR/.build/swiftpm-cache"
CHECK_PACKAGE="$PROJECT_DIR/.build/math-ui-package"
python3 - "$PROJECT_DIR" <<'PY'
import pathlib
import shutil
import sys

root = pathlib.Path(sys.argv[1])
package = root / ".build/math-ui-package"
sources = package / "Sources"
shutil.rmtree(sources, ignore_errors=True)
app = sources / "MathUIChecks"
app.mkdir(parents=True)
shutil.copy2(root / "Sources/FloatingAI/MathMessageView.swift", app / "MathMessageView.swift")
shutil.copy2(root / "Checks/MathUI/main.swift", app / "CheckRunner.swift")
manifest = '''// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "MathUIChecks", platforms: [.macOS(.v13)], targets: [
    .executableTarget(name: "MathUIChecks")
])
'''
manifest_path = package / "Package.swift"
if not manifest_path.exists() or manifest_path.read_text() != manifest:
    manifest_path.write_text(manifest)
PY
swift run --disable-sandbox --package-path "$CHECK_PACKAGE" --cache-path "$PROJECT_DIR/.build/swiftpm-cache" MathUIChecks --resource-dir "$PROJECT_DIR/Resources/MathRendering" "$@"
