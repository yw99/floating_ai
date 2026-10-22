#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$PROJECT_DIR/.build/swiftpm-cache"
# Compile the real app state and Core module together through SwiftPM. A small
# generated package avoids launching AppMain or requiring XCTest, while keeping
# compiler flags and module linkage identical across this executable's targets.
CHECK_PACKAGE="$PROJECT_DIR/.build/app-auth-package"
python3 - "$PROJECT_DIR" <<'PY'
import pathlib
import shutil
import sys

root = pathlib.Path(sys.argv[1])
package = root / ".build/app-auth-package"
sources = package / "Sources"
shutil.rmtree(sources, ignore_errors=True)
shutil.copytree(root / "Sources/FloatingAICore", sources / "FloatingAICore")
app = sources / "AppAuthChecks"
app.mkdir(parents=True)
for name in ("AppStore.swift", "AppModels.swift"):
    shutil.copy2(root / "Sources/FloatingAI" / name, app / name)
shutil.copy2(root / "Checks/AppAuth/main.swift", app / "CheckRunner.swift")
manifest = '''// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "AppAuthChecks", platforms: [.macOS(.v13)], targets: [
    .target(name: "FloatingAICore"),
    .executableTarget(name: "AppAuthChecks", dependencies: ["FloatingAICore"])
])
'''
manifest_path = package / "Package.swift"
if not manifest_path.exists() or manifest_path.read_text() != manifest:
    manifest_path.write_text(manifest)
PY
swift run --disable-sandbox --package-path "$CHECK_PACKAGE" --cache-path "$PROJECT_DIR/.build/swiftpm-cache" AppAuthChecks
