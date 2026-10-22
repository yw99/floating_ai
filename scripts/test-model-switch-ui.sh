#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$PROJECT_DIR/.build/swiftpm-cache"
CHECK_PACKAGE="$PROJECT_DIR/.build/model-switch-ui-package"
python3 - "$PROJECT_DIR" <<'PY'
import pathlib
import shutil
import sys

root = pathlib.Path(sys.argv[1])
package = root / ".build/model-switch-ui-package"
sources = package / "Sources/ModelSwitchUIChecks"
shutil.rmtree(sources, ignore_errors=True)
sources.mkdir(parents=True)
# Compile the actual production popup rather than a test reimplementation.
# The rest of SetupViews (settings, clients, account forms) is not involved.
source = (root / "Sources/FloatingAI/SetupViews.swift").read_text()
marker = "@MainActor struct NewNoteView: View {"
assert source.count(marker) == 1, "Update the popup extraction boundary"
popup = source.split(marker, 1)[0].replace("import FloatingAICore\n", "")
(sources / "NativePopup.swift").write_text(popup)
shutil.copy2(root / "Checks/ModelSwitchUI/main.swift", sources / "CheckRunner.swift")
manifest = '''// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "ModelSwitchUIChecks", platforms: [.macOS(.v13)], targets: [
    .executableTarget(name: "ModelSwitchUIChecks")
])
'''
manifest_path = package / "Package.swift"
if not manifest_path.exists() or manifest_path.read_text() != manifest:
    manifest_path.write_text(manifest)
PY
swift run --disable-sandbox --package-path "$CHECK_PACKAGE" --cache-path "$PROJECT_DIR/.build/swiftpm-cache" ModelSwitchUIChecks
