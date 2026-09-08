#!/usr/bin/env python3
"""Inspect the actual app: identity, packaged resources and forbidden updater code."""
import json
import plistlib
import subprocess
import sys
from pathlib import Path

repo = Path(__file__).resolve().parent.parent
app = Path(sys.argv[1]).resolve()
with (app / "Contents/Info.plist").open("rb") as file:
    info = plistlib.load(file)
assert info["CFBundlePackageType"] == "APPL"
assert info["PWBDistributionChannel"] == "app-store"
assert info["CFBundleIdentifier"] != "ParallelWorkbench", "Store and legacy identity must be distinct"
for purpose in ("NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription"):
    assert info[purpose], f"Missing {purpose}"
framework = app / "Contents/Frameworks/WorkbenchCore.framework"
resources = framework / "Resources"
for directory in ("adapters", "injection"):
    expected = repo / "Sources/WorkbenchCore/Resources" / directory
    for original in expected.iterdir():
        if original.is_file():
            assert (resources / directory / original.name).read_bytes() == original.read_bytes(), f"Resource differs: {original.name}"
assert len(list((resources / "adapters").glob("*.json"))) >= 6
for path in (resources / "adapters").glob("*.json"):
    assert json.loads(path.read_text())["id"]
assert (app / "Contents/Resources/AppIcon.icns").stat().st_size > 0

for path in (app / "Contents/MacOS/ParallelWorkbench", framework / "WorkbenchCore"):
    data = path.read_bytes()
    for forbidden in (b"api.github.com/repos", b"/usr/bin/hdiutil", b"com.apple.quarantine",
                      b"parallel-workbench-relaunch", b"/Applications/ParallelWorkbench.app",
                      b"fetchLatestRelease", b"installDestination", b"scheduleRelaunch"):
        assert forbidden not in data, f"Direct updater code found in {path.name}: {forbidden!r}"
    architectures = subprocess.check_output(["lipo", "-archs", str(path)], text=True).split()
    assert {"arm64", "x86_64"} <= set(architectures), f"Not universal: {path.name}"
print("Verified: application bundle, universal app/framework, packaged resources and absence of direct-updater paths.")
