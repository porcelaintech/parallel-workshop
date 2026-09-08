#!/usr/bin/env python3
"""Read-only structural checks; explicitly not a Windows compiler or runtime test."""
import json
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
subprocess.run([sys.executable, str(root / "scripts/prepare-preview.py"), "--check"], check=True)
for filename in ("Braintrust.NativePreview.csproj", "Package.appxmanifest", "app.manifest", "App.xaml", "Tests/PolicyChecks.csproj"):
    ET.parse(root / filename)
project = ET.parse(root / "Braintrust.NativePreview.csproj").getroot()
expected = {
    "Microsoft.WindowsAppSDK.WinUI": "1.8.260803003",
    "Microsoft.Windows.SDK.BuildTools": "10.0.26100.9169",
    "Microsoft.Web.WebView2": "1.0.4191.47",
}
assert {entry.attrib["Include"]: entry.attrib["Version"] for entry in project.iter("PackageReference")} == expected
ns = {"m": "http://schemas.microsoft.com/appx/manifest/foundation/windows10"}
manifest = ET.parse(root / "Package.appxmanifest").getroot()
identity = manifest.find("m:Identity", ns)
assert identity.attrib == {
    "Name": "Braintrust.NativePreview.Development",
    "Publisher": "CN=Braintrust Native Preview Development", "Version": "0.1.0.0",
}
platforms = json.loads((root / "Config/platforms.json").read_text(encoding="utf-8"))
assert len(platforms) == 3
assert len({p["id"] for p in platforms}) == 3
for path in (root / "Assets").glob("*.png"):
    assert path.read_bytes().startswith(b"\x89PNG\r\n\x1a\n")
print("PASS: preview XML, pinned dependencies, local identity, source-derived platform metadata and assets.")
print("PENDING: C# compilation/policy execution, MSIX build/install/upgrade, WebView2, actual login/upload, Store delivery.")
