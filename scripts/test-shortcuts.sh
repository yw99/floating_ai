#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$PROJECT_DIR/.build/swiftpm-cache"
CHECK_PACKAGE="$PROJECT_DIR/.build/shortcuts-package"
python3 - "$PROJECT_DIR" <<'PY'
import pathlib
import shutil
import sys

root = pathlib.Path(sys.argv[1])
package = root / ".build/shortcuts-package"
sources = package / "Sources"
shutil.rmtree(sources, ignore_errors=True)
core = sources / "FloatingAICore"
app = sources / "ShortcutChecks"
core.mkdir(parents=True)
app.mkdir(parents=True)
shutil.copy2(root / "Sources/FloatingAICore/KeyboardShortcut.swift", core)
shutil.copy2(root / "Sources/FloatingAI/KeyboardShortcutController.swift", app)
shutil.copy2(root / "Checks/Shortcuts/main.swift", app / "CheckRunner.swift")
manifest = '''// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "ShortcutChecks", platforms: [.macOS(.v13)], targets: [
    .target(name: "FloatingAICore"),
    .executableTarget(name: "ShortcutChecks", dependencies: ["FloatingAICore"])
])
'''
manifest_path = package / "Package.swift"
if not manifest_path.exists() or manifest_path.read_text() != manifest:
    manifest_path.write_text(manifest)
PY
swift run --disable-sandbox --package-path "$CHECK_PACKAGE" --cache-path "$PROJECT_DIR/.build/swiftpm-cache" ShortcutChecks "$@"
