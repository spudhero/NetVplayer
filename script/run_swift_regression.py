#!/usr/bin/env python3
"""Run CI regression with bounded silence and stack evidence on a stalled child."""

import argparse
import os
from pathlib import Path
import selectors
import re
import signal
import subprocess
import sys
import tempfile
import time


def sample_children(root):
    rows = subprocess.check_output(["ps", "-axo", "pid=,ppid=,comm="], text=True)
    processes = [line.strip().split(None, 2) for line in rows.splitlines()]
    owned = {root}
    while True:
        children = {int(pid) for pid, parent, _ in processes if int(parent) in owned}
        if children <= owned:
            break
        owned |= children
    for pid, _, command in processes:
        if int(pid) not in owned or not any(name in command for name in ("swiftpm-testing", ".xctest")):
            continue
        with tempfile.TemporaryDirectory(prefix="swift-stall-") as folder:
            output = Path(folder) / "sample.txt"
            subprocess.run(["sample", pid, "2", "-file", str(output)], timeout=15, check=False)
            if output.exists():
                print(output.read_text(errors="replace"), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--idle-timeout", type=float, default=300)
    parser.add_argument("--require-summary", action="store_true",
                        help="Reject success unless every Swift Testing run completed")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if args.idle_timeout <= 0 or not command:
        parser.error("a positive idle timeout and command are required")
    child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
    selector = selectors.DefaultSelector()
    selector.register(child.stdout, selectors.EVENT_READ)
    last_output = time.monotonic()
    pending = b""
    started = completed = 0

    def observe(line):
        nonlocal started, completed
        line = re.sub(rb'\x1b\[[0-?]*[ -/]*[@-~]', b'', line)
        started += int(b'Test run started.' in line)
        completed += int(re.search(rb'Test run with [0-9,]+ tests? passed', line) is not None)
    try:
        while True:
            for key, _ in selector.select(timeout=min(1, args.idle_timeout)):
                data = os.read(key.fd, 65536)
                if not data:
                    selector.unregister(key.fd)
                    if pending:
                        observe(pending)
                        pending = b""
                    continue
                sys.stdout.buffer.write(data)
                sys.stdout.buffer.flush()
                last_output = time.monotonic()
                pending += data
                lines = pending.split(b"\n")
                pending = lines.pop()
                for line in lines:
                    observe(line)
            if child.poll() is not None and not selector.get_map():
                if child.returncode == 0 and args.require_summary and (started == 0 or completed != started):
                    print(f"Swift Testing did not finish: {started} runs started, {completed} completed.", flush=True)
                    return 125
                return child.returncode
            if time.monotonic() - last_output >= args.idle_timeout:
                print("\nRegression stalled: collecting owned test process stacks.", flush=True)
                if sys.platform == "darwin":
                    try:
                        sample_children(child.pid)
                    except (OSError, subprocess.SubprocessError) as error:
                        print(f"Stack collection unavailable: {type(error).__name__}", flush=True)
                return 124
    finally:
        selector.close()
        if child.poll() is None:
            os.killpg(child.pid, signal.SIGTERM)
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()


if __name__ == "__main__":
    sys.exit(main())
