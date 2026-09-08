#!/usr/bin/env bash
set -euo pipefail
task_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
task_app="${1:-$task_repo/build/macos-store-unsigned/ParallelWorkbench.xcarchive/Products/Applications/ParallelWorkbench.app}"
task_frameworks="$task_app/Contents/Frameworks"
task_test_root="$(mktemp -d /tmp/braintrust-store-checks.XXXXXX)"
trap 'rm -rf "$task_test_root"' EXIT
swiftc -parse-as-library -F "$task_frameworks" -framework WorkbenchCore \
  -Xlinker -rpath -Xlinker "$task_frameworks" \
  "$task_repo/macOS/Store/Tests/StoreUpdateCoordinatorChecks.swift" -o "$task_test_root/checks"
# Run away from the source tree, so bundled resource resolution is exercised.
(cd "$task_test_root" && ./checks)
