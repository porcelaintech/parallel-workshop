#!/usr/bin/env bash
# Local builds only. This script never installs, registers an account, or uploads.
set -euo pipefail
task_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
task_mode="${1:-unsigned}"
task_action="${2:-archive}"
case "$task_mode" in unsigned|signed) ;; *) echo "Usage: $0 [unsigned|signed] [build|archive]" >&2; exit 2;; esac
case "$task_action" in build|archive) ;; *) echo "Action must be build or archive." >&2; exit 2;; esac
command -v xcodegen >/dev/null || { echo "XcodeGen 2.46+ is required." >&2; exit 1; }
command -v python3 >/dev/null || { echo "Python 3 is required." >&2; exit 1; }
if [[ "$task_mode" == signed ]]; then
  python3 "$task_repo/scripts/macos-store-preflight.py"
fi

task_version="${PWB_APP_VERSION:-$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$task_repo/Windows/edge-extension/manifest.json")}"
task_build_number="${PWB_BUILD_NUMBER:-1}"
[[ "$task_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid PWB_APP_VERSION." >&2; exit 1; }
[[ "$task_build_number" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid PWB_BUILD_NUMBER." >&2; exit 1; }
task_project="$task_repo/macOS/Store"
task_output="$task_repo/build/macos-store-$task_mode"
mkdir -p "$task_output" "$task_project/Generated"

# Do not let unrelated shell secrets enter Xcode diagnostic attachments.
task_user="$(id -un)"
task_clean_env=(env -i "PATH=$PATH" "HOME=$HOME" "USER=$task_user" "LOGNAME=$task_user" "TMPDIR=${TMPDIR:-/tmp}" "LANG=en_US.UTF-8")
if [[ -n "${DEVELOPER_DIR:-}" ]]; then task_clean_env+=("DEVELOPER_DIR=$DEVELOPER_DIR"); fi
if ! "${task_clean_env[@]}" xcodebuild -checkFirstLaunchStatus >"$task_output/first-launch.log" 2>&1; then
  echo "Xcode first-launch components are not ready. Complete Xcode's official initial setup before creating an archive." >&2
  echo "Diagnostic: $task_output/first-launch.log" >&2
  echo "A local compiler-only preview is available via scripts/macos-store-preview.sh; it is not an Xcode archive." >&2
  exit 1
fi
"${task_clean_env[@]}" swift "$task_repo/scripts/icon.swift" "$task_project/Generated/AppIcon.iconset"
iconutil -c icns "$task_project/Generated/AppIcon.iconset" -o "$task_project/Generated/AppIcon.icns"
"${task_clean_env[@]}" xcodegen generate --spec "$task_project/project.yml" --project "$task_project"

task_args=(
  -project "$task_project/ParallelWorkbenchStore.xcodeproj"
  -scheme ParallelWorkbenchStore -configuration Release
  -destination "generic/platform=macOS"
  -derivedDataPath "$task_output/DerivedData"
  "MARKETING_VERSION=$task_version" "CURRENT_PROJECT_VERSION=$task_build_number"
  "PWB_APP_STORE_ID=${PWB_APP_STORE_ID:-}" "PWB_COPYRIGHT=${PWB_COPYRIGHT:-}"
)
if [[ "$task_mode" == unsigned ]]; then
  task_args+=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
    "PWB_STORE_BUNDLE_ID=${PWB_STORE_BUNDLE_ID:-local.braintrust.storepreview}")
else
  task_args+=("PWB_STORE_BUNDLE_ID=$PWB_STORE_BUNDLE_ID" "DEVELOPMENT_TEAM=$PWB_APPLE_TEAM_ID")
fi
if [[ "$task_action" == archive ]]; then
  task_args+=(-archivePath "$task_output/ParallelWorkbench.xcarchive")
fi
task_log="$task_output/$task_action.log"
if ! "${task_clean_env[@]}" xcodebuild "${task_args[@]}" "$task_action" >"$task_log" 2>&1; then
  tail -n 65 "$task_log" >&2
  echo "Build failed. Log: $task_log" >&2
  exit 1
fi
if [[ "$task_action" == archive ]]; then
  task_app="$task_output/ParallelWorkbench.xcarchive/Products/Applications/ParallelWorkbench.app"
else
  task_app="$task_output/DerivedData/Build/Products/Release/ParallelWorkbench.app"
fi
task_verify_args=("$task_app")
if [[ "$task_action" == archive ]]; then
  task_verify_args+=(--archive "$task_output/ParallelWorkbench.xcarchive")
fi
python3 "$task_repo/scripts/macos-store-verify.py" "${task_verify_args[@]}"
echo "Mac Store $task_mode $task_action completed: $task_app"
echo "No installation or upload performed. Unsigned results are not distributable Store releases."
