#!/usr/bin/env bash
# Diagnostic fallback if Xcode's first-launch components cannot initialize.
# Builds a local APP_STORE preview with swiftc; this is NOT an Xcode archive.
set -euo pipefail
task_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
task_output="$task_repo/build/macos-store-preview"
task_app="$task_output/ParallelWorkbench.app"
task_framework="$task_app/Contents/Frameworks/WorkbenchCore.framework"
task_framework_a="$task_framework/Versions/A"
task_sdk="$(xcrun --sdk macosx --show-sdk-path)"
task_version="${PWB_APP_VERSION:-$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$task_repo/Windows/edge-extension/manifest.json")}"
[[ "$task_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid PWB_APP_VERSION." >&2; exit 1; }
mkdir -p "$task_output/objects" "$task_app/Contents/MacOS" "$task_app/Contents/Resources" \
  "$task_framework_a/Modules/WorkbenchCore.swiftmodule" "$task_framework_a/Resources"
ln -sfn A "$task_framework/Versions/Current"
ln -sfn Versions/Current/WorkbenchCore "$task_framework/WorkbenchCore"
ln -sfn Versions/Current/Resources "$task_framework/Resources"
ln -sfn Versions/Current/Modules "$task_framework/Modules"
cp -R "$task_repo/Sources/WorkbenchCore/Resources/adapters" "$task_framework_a/Resources/"
cp -R "$task_repo/Sources/WorkbenchCore/Resources/injection" "$task_framework_a/Resources/"
task_sources=()
for task_source in "$task_repo"/Sources/WorkbenchCore/*.swift; do
  case "$(basename "$task_source")" in Updater.swift|UpdaterRelaunch.swift|UpdateCoordinator.swift) continue;; esac
  task_sources+=("$task_source")
done
task_user="$(id -un)"
task_clean_env=(env -i "PATH=$PATH" "HOME=$HOME" "USER=$task_user" "LOGNAME=$task_user" "TMPDIR=${TMPDIR:-/tmp}" "LANG=en_US.UTF-8")
if [[ -n "${DEVELOPER_DIR:-}" ]]; then task_clean_env+=("DEVELOPER_DIR=$DEVELOPER_DIR"); fi
for task_arch in arm64 x86_64; do
  "${task_clean_env[@]}" swiftc -D APP_STORE -swift-version 5 -O -parse-as-library \
    -target "$task_arch-apple-macos13.0" -sdk "$task_sdk" \
    -emit-library -emit-module -module-name WorkbenchCore \
    -emit-module-path "$task_framework_a/Modules/WorkbenchCore.swiftmodule/$task_arch-apple-macos.swiftmodule" \
    -Xlinker -install_name -Xlinker '@rpath/WorkbenchCore.framework/Versions/A/WorkbenchCore' \
    "${task_sources[@]}" -o "$task_output/objects/WorkbenchCore-$task_arch"
done
lipo -create "$task_output/objects/WorkbenchCore-arm64" "$task_output/objects/WorkbenchCore-x86_64" -output "$task_framework_a/WorkbenchCore"
for task_arch in arm64 x86_64; do
  "${task_clean_env[@]}" swiftc -D APP_STORE -swift-version 5 -O -parse-as-library \
    -target "$task_arch-apple-macos13.0" -sdk "$task_sdk" \
    -F "$task_app/Contents/Frameworks" -framework WorkbenchCore \
    -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
    "$task_repo"/Sources/ParallelWorkbench/*.swift -o "$task_output/objects/ParallelWorkbench-$task_arch"
done
lipo -create "$task_output/objects/ParallelWorkbench-arm64" "$task_output/objects/ParallelWorkbench-x86_64" -output "$task_app/Contents/MacOS/ParallelWorkbench"
"${task_clean_env[@]}" swift "$task_repo/scripts/icon.swift" "$task_output/AppIcon.iconset"
iconutil -c icns "$task_output/AppIcon.iconset" -o "$task_app/Contents/Resources/AppIcon.icns"
python3 - "$task_repo" "$task_app" "$task_version" <<'PY'
import plistlib, sys
from pathlib import Path
repo, app = map(Path, sys.argv[1:3])
with (repo / 'macOS/Store/Info.plist').open('rb') as file:
    info = plistlib.load(file)
values = dict(EXECUTABLE_NAME='ParallelWorkbench', PRODUCT_BUNDLE_IDENTIFIER='local.braintrust.storepreview', MARKETING_VERSION=sys.argv[3], CURRENT_PROJECT_VERSION='1', MACOSX_DEPLOYMENT_TARGET='13.0', PWB_APP_STORE_ID='', PWB_COPYRIGHT='')
for key, value in info.items():
    if isinstance(value, str):
        for setting, replacement in values.items():
            value = value.replace('$(' + setting + ')', replacement)
        info[key] = value
info['PWBArtifactType'] = 'swiftc-local-preview-not-xcode-archive'
with (app / 'Contents/Info.plist').open('wb') as file:
    plistlib.dump(info, file)
with (app / 'Contents/Frameworks/WorkbenchCore.framework/Resources/Info.plist').open('wb') as file:
    plistlib.dump(dict(CFBundleIdentifier='local.braintrust.storepreview.core', CFBundleName='WorkbenchCore', CFBundleExecutable='WorkbenchCore', CFBundlePackageType='FMWK', CFBundleVersion='1'), file)
PY
python3 "$task_repo/scripts/macos-store-verify.py" "$task_app"
bash "$task_repo/scripts/macos-store-test.sh" "$task_app"
echo "Local swiftc preview only (not an Xcode archive): $task_app"
echo "No signing, installation, account operation, or upload performed."
