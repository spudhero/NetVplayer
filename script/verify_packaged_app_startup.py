"""Launch an extracted release app without its SwiftPM build resource fallback."""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile


@contextmanager
def hidden_build_resources(bundle: Path):
    if os.environ.get("CI") != "true":
        raise ValueError("hiding build resources is restricted to an isolated CI runner")
    if bundle.name != "NetVplayer_NetVplayerApp.bundle" or not bundle.is_dir() or bundle.is_symlink():
        raise ValueError("expected the real SwiftPM application resource bundle")
    temporary = Path(tempfile.mkdtemp(prefix=".startup-resource-fallback-", dir=bundle.parent))
    hidden = temporary / bundle.name
    bundle.rename(hidden)
    try:
        yield
    finally:
        # If restoration itself fails, preserve the hidden original for recovery.
        hidden.rename(bundle)
        temporary.rmdir()


def verify(app: Path, build_resources: Path, output: Path) -> dict:
    app = app.resolve(strict=True)
    build_resources = build_resources.resolve(strict=True)
    if app.suffix != ".app" or not (app / "Contents/MacOS/NetVplayerApp").is_file():
        raise ValueError("expected an extracted NetVplayer application")
    packaged = app / "Contents/Resources/NetVplayer_NetVplayerApp.bundle"
    if not packaged.is_dir() or packaged.resolve() == build_resources:
        raise ValueError("packaged resources must be independent of the build resources")
    output.mkdir(parents=True, exist_ok=False)
    capture = output / "startup.png"
    # This existing mode skips saved-state restoration, providers, diagnostics and
    # update checks, but still executes AppState's real theme publication path.
    command = ["/usr/bin/open", "-n", "-F", "-W",
               "--env", "NSUnbufferedIO=YES",
               "--stdout", str((output / "app.stdout.log").resolve()),
               "--stderr", str((output / "app.stderr.log").resolve()), str(app), "--args",
               "--visual-regression-player", "normal",
               "--visual-regression-viewport", "1200x675",
               "--visual-regression-output", str(capture.resolve())]
    launch_completed = False
    try:
        with hidden_build_resources(build_resources):
            subprocess.run(command, check=True, timeout=90, capture_output=True, text=True)
            launch_completed = True
            data = capture.read_bytes()
            if (len(data) < 33 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR"
                    or struct.unpack(">II", data[16:24]) != (1200, 675)):
                raise ValueError("packaged app did not produce the expected startup capture")
    except Exception as error:
        failure = {"failure_type": type(error).__name__, "launch_completed": launch_completed,
                   "capture_exists": capture.is_file(),
                   "build_resources_restored": build_resources.is_dir()}
        (output / "failure.json").write_text(json.dumps(failure, indent=2) + "\n")
        raise
    receipt = {"packaged_app_started": True, "swiftpm_build_resources_hidden": True,
               "build_resources_restored": build_resources.is_dir(), "capture": capture.name,
               "viewport": [1200, 675]}
    (output / "result.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return receipt


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app-bundle", type=Path, required=True)
    parser.add_argument("--build-resources", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(verify(args.app_bundle, args.build_resources, args.output)))


if __name__ == "__main__":
    main()
