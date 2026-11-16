"""Exercise the production quit delegate in a small, isolated AppKit application."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import uuid


ROOT = Path(__file__).resolve().parents[1]


def verify(output: Path) -> dict:
    source = (ROOT / "NetVplayer/Sources/NetVplayerApp/NetVplayerApp.swift").read_text()
    start = source.index("    func applicationShouldTerminate(_ sender:")
    end = source.index("\n    }\n", start) + len("\n    }")
    method = source[start:end]
    fixture = (ROOT / "script/fixtures/application_termination.swift").read_text()
    output = output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    app = output / "TerminationProbe.app"
    executable = app / "Contents/MacOS/TerminationProbe"
    executable.parent.mkdir(parents=True)
    info = {"CFBundleExecutable": executable.name, "CFBundlePackageType": "APPL",
            "CFBundleIdentifier": "dev.netvplayer.termination-probe." + uuid.uuid4().hex,
            "CFBundleName": "NetVplayer Termination Probe", "LSUIElement": True,
            "NSPrincipalClass": "NSApplication"}
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    generated = output / "Probe.swift"
    generated.write_text(fixture.replace("    // __APPLICATION_SHOULD_TERMINATE__", method))
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-strict-concurrency=complete",
                    "-warnings-as-errors", "-module-cache-path", str(output / "modules"),
                    str(generated), "-o", str(executable)], check=True, timeout=120)
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
    cases = {}
    for scenario in ("concurrent", "retry", "handoff"):
        stdout, stderr = output / f"{scenario}.stdout.log", output / f"{scenario}.stderr.log"
        command = ["/usr/bin/open", "-n", "-F", "-W", "--stdout", str(stdout),
                   "--stderr", str(stderr), str(app), "--args", scenario]
        try:
            subprocess.run(command, check=True, timeout=10, capture_output=True, text=True)
        except subprocess.TimeoutExpired:
            # Terminate only this fixture's recorded PID after verifying its executable.
            lines = stdout.read_text().splitlines() if stdout.exists() else []
            pids = [int(line.split(":", 1)[1]) for line in lines if line.startswith("fixture_pid:")]
            if len(pids) == 1:
                ownership = subprocess.run(["lsof", "-a", "-p", str(pids[0]), "-d", "txt", "-Fn"],
                                           capture_output=True, text=True)
                if "n" + str(executable) in ownership.stdout.splitlines():
                    os.kill(pids[0], signal.SIGTERM)
            raise
        log = stdout.read_text().splitlines()
        attempts = 2 if scenario == "retry" else 1
        assert f"will_terminate:{attempts}" in log, log
        assert f"cleanup_completed:{attempts}" in log, log
        if scenario == "retry":
            assert "cleanup_failed_app_retained" in log, log
        elif scenario == "handoff":
            assert "handoff_preserved" in log, log
        else:
            assert "concurrent_quit" in log, log
        cases[scenario] = {"passed": True, "cleanup_attempts": attempts}
    receipt = {"production_method_sha256": hashlib.sha256(method.encode()).hexdigest(),
               "native_appkit_cases": cases, "all_passed": True}
    (output / "result.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return receipt


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    print(json.dumps(verify(parser.parse_args().output)))
