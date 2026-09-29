#!/usr/bin/env python3
"""Build the Tauri updater manifest (latest.json) from release artifacts.

Run in the release workflow after all platform builds have uploaded their
artifacts to the release. Scans the downloaded artifact files:

  SyncPilot_<version>_x64.AppImage      (+ .sig)
  SyncPilot_<version>_aarch64.AppImage  (+ .sig)

and writes latest.json in the Tauri v2 static-manifest format with one
entry per platform signature. The AppImage URL points at the same release.

Usage: gen-update-manifest.py <version> <download-base> <artifact-dir> <out.json>
Example:
  gen-update-manifest.py 0.2.0 \
    https://github.com/turinglambdaai/syncpilot/releases/download/v0.2.0 \
    artifacts/ latest.json
"""

import json
import sys
from pathlib import Path

# AppImage updater platform keys (Tauri v2 static manifest). The bundler
# names AppImages with deb-style arch suffixes: x86_64 target -> amd64.
PLATFORMS = {
    "amd64": "linux-x86_64",
    "x64": "linux-x86_64",
    "aarch64": "linux-aarch64",
}


def main() -> int:
    if len(sys.argv) != 5:
        print(__doc__)
        return 2
    version, base, artifact_dir, out_path = sys.argv[1:5]
    artifact_dir = Path(artifact_dir)

    platforms = {}
    for suffix, key in PLATFORMS.items():
        if key in platforms:
            continue  # alternate spelling of an arch already found
        appimage = sorted(artifact_dir.glob(f"SyncPilot_*_{suffix}.AppImage"))
        if not appimage:
            continue
        appimage = appimage[-1]
        sigs = sorted(artifact_dir.glob(f"{appimage.name}.sig"))
        if not sigs:
            print(f"error: no .sig for {appimage.name}", file=sys.stderr)
            return 1
        platforms[key] = {
            "signature": sigs[-1].read_text().strip(),
            "url": f"{base}/{appimage.name}",
        }

    if not platforms:
        print("error: no updater artifacts found", file=sys.stderr)
        return 1

    manifest = {
        "version": version.lstrip("v"),
        "notes": f"SyncPilot {version}",
        "pub_date": __import__("datetime").datetime.now(
            __import__("datetime").timezone.utc
        ).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "platforms": platforms,
    }
    Path(out_path).write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"wrote {out_path} with platforms: {sorted(platforms)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
