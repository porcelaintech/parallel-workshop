#!/usr/bin/env python3
"""Copy only platform metadata, and create deterministic placeholder package icons.

--check is read-only. No production adapter or image is modified.
"""
import argparse
import json
from pathlib import Path
import struct
import zlib

PREVIEW = Path(__file__).resolve().parents[1]
REPO = PREVIEW.parents[1]
PLATFORMS = ("chatgpt", "deepseek", "doubao")
# Candidate authentication destinations already present in the extension's manifest.
# These exact-host entries permit validation, and are not claims that login succeeds.
AUTH_HOSTS = {
    "chatgpt": ["appleid.apple.com"],
    "deepseek": ["open.weixin.qq.com", "appleid.apple.com"],
    "doubao": ["open.weixin.qq.com"],
}


def package_icon(size):
    """A code-generated three-panel preview marker, not final Store artwork."""
    def chunk(kind, payload):
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload))
    rows = bytearray()
    for y in range(size):
        rows.append(0)
        for x in range(size):
            inside = size * .23 <= y < size * .77
            pane = any(size * left <= x < size * right for left, right in ((.16, .35), (.405, .595), (.65, .84)))
            rows.extend((218, 229, 252, 255) if inside and pane else (35, 57, 99, 255))
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")


def outputs():
    definitions = []
    for platform_id in PLATFORMS:
        source = REPO / "Sources/WorkbenchCore/Resources/adapters" / (platform_id + ".json")
        adapter = json.loads(source.read_text())
        definitions.append({
            "id": adapter["id"], "name": adapter["name"], "origin": adapter["origin"],
            "navigationHosts": list(dict.fromkeys(adapter["homeHosts"] + AUTH_HOSTS[platform_id])),
        })
    yield PREVIEW / "Config/platforms.json", (json.dumps(definitions, ensure_ascii=False, indent=2) + "\n").encode()
    for filename, size in (("StoreLogo.png", 50), ("Square44x44Logo.png", 44), ("Square150x150Logo.png", 150)):
        yield PREVIEW / "Assets" / filename, package_icon(size)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args()
    for path, expected in outputs():
        if arguments.check:
            if not path.exists() or path.read_bytes() != expected:
                raise SystemExit(f"Preview metadata/asset is stale: {path.relative_to(PREVIEW)}")
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(expected)
    print("Preview metadata and package assets match source." if arguments.check else "Preview metadata and package assets generated.")
