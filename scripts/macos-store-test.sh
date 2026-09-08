#!/usr/bin/env bash
set -euo pipefail
task_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# -gt 2 ]]; then
  echo "Usage: $0 [APP_PATH [MODULES_DIR]]" >&2
  exit 2
fi
task_app="${1:-$task_repo/build/macos-store-unsigned/ParallelWorkbench.xcarchive/Products/Applications/ParallelWorkbench.app}"
[[ -d "$task_app" ]] || { echo "Application not found: $task_app" >&2; exit 1; }
task_app="$(cd "$task_app" && pwd -P)"
task_frameworks="$task_app/Contents/Frameworks"
task_runtime_binary="$task_frameworks/WorkbenchCore.framework/WorkbenchCore"
[[ -f "$task_runtime_binary" ]] || { echo "Archived WorkbenchCore framework not found: $task_runtime_binary" >&2; exit 1; }

# Xcode strips Modules when embedding a framework in an archive. Import the
# matching build's type metadata without using its framework for linking/loading.
task_modules="${2:-}"
if [[ -z "$task_modules" && -d "$task_frameworks/WorkbenchCore.framework/Modules/WorkbenchCore.swiftmodule" ]]; then
  task_modules="$task_frameworks/WorkbenchCore.framework/Modules"
elif [[ -z "$task_modules" ]]; then
  case "$task_app" in
    */ParallelWorkbench.xcarchive/Products/Applications/ParallelWorkbench.app)
      task_archive_output="${task_app%/ParallelWorkbench.xcarchive/Products/Applications/ParallelWorkbench.app}"
      task_modules="$task_archive_output/DerivedData/Build/Intermediates.noindex/ArchiveIntermediates/ParallelWorkbenchStore/IntermediateBuildFilesPath/UninstalledProducts/macosx/WorkbenchCore.framework/Modules"
      ;;
  esac
fi
if [[ -z "$task_modules" || ! -d "$task_modules/WorkbenchCore.swiftmodule" ]]; then
  echo "The app's framework has no importable Swift module metadata." >&2
  echo "Pass a second argument: the matching Xcode-built WorkbenchCore.framework/Modules directory." >&2
  echo "Usage: $0 APP_PATH MODULES_DIR. No recursive or preview-framework fallback is performed." >&2
  exit 1
fi
task_modules="$(cd "$task_modules" && pwd -P)"
task_module_binary="$task_modules/../WorkbenchCore"
[[ -f "$task_module_binary" ]] || { echo "Modules must belong to a matching built WorkbenchCore.framework (sibling binary missing)." >&2; exit 1; }
python3 - "$task_runtime_binary" "$task_module_binary" <<'PY'
import re, subprocess, sys
def uuids(path):
    output = subprocess.check_output(['xcrun', 'dwarfdump', '--uuid', path], text=True)
    return dict((arch, uuid) for uuid, arch in re.findall(r'UUID: ([0-9A-Fa-f-]+) \(([^)]+)\)', output))
runtime, metadata = map(uuids, sys.argv[1:])
if not runtime or runtime != metadata:
    sys.exit('Module metadata belongs to a different framework build (Mach-O UUID mismatch).')
print('Verified module provenance: metadata framework UUIDs match the application framework.')
PY

task_test_root="$(mktemp -d /tmp/braintrust-store-checks.XXXXXX)"
trap 'rm -rf "$task_test_root"' EXIT
swiftc -parse-as-library -I "$task_modules" -F "$task_frameworks" -framework WorkbenchCore \
  -Xlinker -rpath -Xlinker "$task_frameworks" \
  "$task_repo/macOS/Store/Tests/StoreUpdateCoordinatorChecks.swift" -o "$task_test_root/checks"
# Run away from the source tree. Clear inherited DYLD overrides and verify the
# actual loaded binary, so build-time module imports cannot mask archive defects.
task_user="$(id -un)"
if ! (cd "$task_test_root" && env -i "PATH=$PATH" "HOME=$HOME" "USER=$task_user" "LOGNAME=$task_user" \
  "TMPDIR=${TMPDIR:-/tmp}" DYLD_PRINT_LIBRARIES=1 ./checks 2>dyld.log); then
  tail -n 20 "$task_test_root/dyld.log" >&2
  exit 1
fi
python3 - "$task_runtime_binary" "$task_test_root/dyld.log" <<'PY'
from pathlib import Path
import sys
expected = str(Path(sys.argv[1]).resolve())
if expected not in Path(sys.argv[2]).read_text():
    sys.exit('Could not confirm that the test loaded the application framework.')
print('Verified runtime loading: the tested framework is the one inside the supplied application.')
PY
