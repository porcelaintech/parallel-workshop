#!/usr/bin/env python3
"""Inspect the app and, when supplied, its Xcode application archive."""
import argparse
from datetime import datetime
import json
import plistlib
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("app", type=Path)
parser.add_argument("--archive", type=Path, help="Also require a genuine application archive structure")
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
app = args.app.resolve()
with (app / "Contents/Info.plist").open("rb") as file:
    info = plistlib.load(file)
assert info["CFBundlePackageType"] == "APPL"
assert info["PWBDistributionChannel"] == "app-store"
assert info["CFBundleIdentifier"] != "ParallelWorkbench", "Store and legacy identity must be distinct"
if args.archive:
    archive = args.archive.resolve()
    with (archive / "Info.plist").open("rb") as file:
        archive_info = plistlib.load(file)
    properties = archive_info.get("ApplicationProperties")
    assert isinstance(properties, dict), "Generic archive: missing ApplicationProperties"
    assert archive_info.get("ArchiveVersion") == 2, "Unexpected archive format"
    assert archive_info.get("SchemeName") == "ParallelWorkbenchStore", "Unexpected archive scheme"
    assert isinstance(archive_info.get("CreationDate"), datetime), "Missing archive creation date"
    assert properties.get("ApplicationPath") == "Applications/ParallelWorkbench.app", "Unexpected archive application path"
    products = archive / "Products"
    assert {path.name for path in products.iterdir()} == {"Applications"}, "Extra top-level archive products"
    assert {path.name for path in (products / "Applications").iterdir()} == {"ParallelWorkbench.app"}, "Archive must contain exactly one application"
    assert (products / properties["ApplicationPath"]).resolve() == app, "App does not belong to this archive"
    for key in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion"):
        assert properties.get(key) == info[key], f"Archive/app metadata differs: {key}"
    assert set(properties.get("Architectures", [])) == {"arm64", "x86_64"}, "Archive metadata is not universal"
    assert "PWBArtifactType" not in info, "Compiler-only preview is not an Xcode archive"
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
if args.archive:
    print("Verified: Xcode application archive structure and matching app metadata (not a generic archive or compiler-only preview).")
