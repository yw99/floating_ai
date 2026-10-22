#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$PROJECT_DIR/.build/swiftpm-cache"
swift build --disable-sandbox --product FloatingAIFileTool --cache-path "$PROJECT_DIR/.build/swiftpm-cache"
BIN_DIR="$(swift build --disable-sandbox --show-bin-path --cache-path "$PROJECT_DIR/.build/swiftpm-cache")"
python3 scripts/test-file-reader.py "$BIN_DIR/FloatingAIFileTool"
python3 - "$PROJECT_DIR" <<'PY'
import pathlib, shutil, sys
root = pathlib.Path(sys.argv[1])
package = root / ".build/files-package"
sources = package / "Sources"
shutil.rmtree(sources, ignore_errors=True)
shutil.copytree(root / "Sources/FloatingAICore", sources / "FloatingAICore")
app = sources / "FilesChecks"
app.mkdir(parents=True)
for name in ("AppStore.swift", "AppModels.swift"):
    shutil.copy2(root / "Sources/FloatingAI" / name, app / name)
shutil.copy2(root / "Checks/Files/main.swift", app / "CheckRunner.swift")
(package / "Package.swift").write_text('''// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "FilesChecks", platforms: [.macOS(.v13)], targets: [
    .target(name: "FloatingAICore"),
    .executableTarget(name: "FilesChecks", dependencies: ["FloatingAICore"])
])
''')
PY
swift run --disable-sandbox --package-path "$PROJECT_DIR/.build/files-package" --cache-path "$PROJECT_DIR/.build/swiftpm-cache" FilesChecks
