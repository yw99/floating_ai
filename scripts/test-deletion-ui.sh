#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$PROJECT_DIR/.build/swiftpm-cache"
CHECK_PACKAGE="$PROJECT_DIR/.build/deletion-ui-package"
python3 - "$PROJECT_DIR" <<'PY'
import pathlib
import shutil
import sys

root = pathlib.Path(sys.argv[1])
package = root / ".build/deletion-ui-package"
sources = package / "Sources"
shutil.rmtree(sources, ignore_errors=True)
shutil.copytree(root / "Sources/FloatingAICore", sources / "FloatingAICore")
app = sources / "DeletionUIChecks"
app.mkdir(parents=True)
for source in (root / "Sources/FloatingAI").glob("*.swift"):
    if source.name not in ("AppMain.swift", "PreviewRenderer.swift"):
        shutil.copy2(source, app / source.name)
shutil.copy2(root / "Checks/DeletionUI/main.swift", app / "CheckRunner.swift")
manifest = '''// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "DeletionUIChecks", platforms: [.macOS(.v13)], targets: [
    .target(name: "FloatingAICore"),
    .executableTarget(name: "DeletionUIChecks", dependencies: ["FloatingAICore"])
])
'''
manifest_path = package / "Package.swift"
if not manifest_path.exists() or manifest_path.read_text() != manifest:
    manifest_path.write_text(manifest)
PY
swift run --disable-sandbox --package-path "$CHECK_PACKAGE" --cache-path "$PROJECT_DIR/.build/swiftpm-cache" DeletionUIChecks
