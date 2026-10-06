#!/usr/bin/env python3
"""Capture installed FongMi home screens for the current site's audit inventory.

All taps and swipes derive from fresh UI XML bounds. This captures visible home
evidence only: neither a nonempty grid nor a selected episode proves playback.
"""

from __future__ import annotations

import argparse
from datetime import datetime
import json
from pathlib import Path
import re
import subprocess
import time
import xml.etree.ElementTree as ET

from audit_current_source_parity import save


class Device:
    def __init__(self, serial, evidence):
        self.serial, self.evidence, self.sequence = serial, evidence, int(time.time() * 1000)

    def adb(self, *args, timeout=25):
        return subprocess.check_output(["adb", "-s", self.serial, *args], timeout=timeout)

    def dump(self, label):
        self.sequence += 1
        for attempt in range(3):
            raw = self.adb("exec-out", "uiautomator", "dump", "/dev/tty").decode(errors="replace")
            if "<?xml" in raw and "</hierarchy>" in raw:
                break
            if attempt == 2:
                raise RuntimeError("uiautomator-did-not-return-a-complete-tree")
        xml = raw[raw.index("<?xml"):raw.index("</hierarchy>") + len("</hierarchy>")]
        path = self.evidence / f"android-{label}-{self.sequence:04}.xml"
        path.write_text(xml)
        return ET.fromstring(xml), str(path)

    @staticmethod
    def bounds(node):
        return list(map(int, re.findall(r"\d+", node.get("bounds", ""))))

    def tap(self, node):
        x1, y1, x2, y2 = self.bounds(node)
        self.adb("shell", "input", "tap", str((x1+x2)//2), str((y1+y2)//2))

    def swipe(self, node, direction):
        x1, y1, x2, y2 = self.bounds(node)
        x = (x1+x2)//2
        top, bottom = y1 + (y2-y1)//5, y2 - (y2-y1)//5
        start, end = (bottom, top) if direction == "down" else (top, bottom)
        self.adb("shell", "input", "swipe", str(x), str(start), str(x), str(end), "350")

    def home(self):
        self.adb("shell", "am", "start", "-n", "com.fongmi.android.tv/.ui.activity.HomeActivity")
        for _ in range(6):
            tree, _ = self.dump("home-entry")
            title = next((n for n in tree.iter("node") if n.get("resource-id", "").endswith(":id/title")), None)
            if title is not None:
                return tree, title
            vod = next((n for n in tree.iter("node") if n.get("content-desc") == "点播"), None)
            if vod is not None:
                self.tap(vod)
            elif any(n.get("resource-id", "").endswith((":id/site", ":id/exo_content_frame")) for n in tree.iter("node")):
                self.adb("shell", "input", "keyevent", "KEYCODE_BACK")
            else:
                raise RuntimeError("unrecognized-screen-while-returning-home")
        else:
            raise RuntimeError("home-navigation-limit")

    def select(self, target, order):
        tree, title = self.home()
        if title.get("text") == target:
            return
        self.tap(title)
        previous = None
        for _ in range(30):
            tree, _ = self.dump("site-menu")
            buttons = [n for n in tree.iter("node") if n.get("class") == "android.widget.Button" and n.get("text") in order]
            container = next(n for n in tree.iter("node") if n.get("scrollable") == "true")
            match = next((n for n in buttons if n.get("text") == target), None)
            if match is not None and self.bounds(match)[3] - self.bounds(match)[1] >= 24:
                self.tap(match)
                return
            names = tuple(n.get("text") for n in buttons)
            if names == previous:
                raise RuntimeError("site-menu-ended-before-target")
            previous = names
            direction = "up" if buttons and order[buttons[0].get("text")] > order[target] else "down"
            self.swipe(container, direction)
        raise RuntimeError("site-menu-scroll-limit")

    def observe_home(self, ordinal, expected_site):
        started = time.monotonic()
        deadline = started + 30
        while True:
            tree, path = self.dump(f"{ordinal:02}-home")
            names = [n.get("text") for n in tree.iter("node") if n.get("resource-id", "").endswith(":id/name") and n.get("text")]
            category_node = next((n for n in tree.iter("node") if n.get("resource-id", "").endswith(":id/type")), None)
            categories = [n.get("text") for n in category_node.iter("node") if n.get("text")] if category_node is not None else []
            loading = any(n.get("resource-id", "").endswith(":id/progress") for n in tree.iter("node"))
            if names or (not loading and time.monotonic() - started >= 5) or time.monotonic() > deadline:
                break
            time.sleep(1)
        selected_site = next((n.get("text") for n in tree.iter("node") if n.get("resource-id", "").endswith(":id/title")), None)
        if selected_site != expected_site:
            raise RuntimeError("selected-site-does-not-match-requested-site")
        image = self.evidence / f"android-{ordinal:02}-home-{self.sequence}.png"
        image.write_bytes(self.adb("exec-out", "screencap", "-p"))
        return {"status": "visible_content" if names else "empty_or_utility",
                "selected_site": selected_site, "visible_categories": categories, "visible_titles": names,
                "xml": path, "screenshot": str(image), "loading_at_capture": loading,
                "observed_at": datetime.now().astimezone().isoformat(timespec="seconds")}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--serial", required=True)
    p.add_argument("--inventory", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--evidence", type=Path, required=True)
    p.add_argument("--only", action="append", default=[])
    p.add_argument("--redo", action="store_true")
    args = p.parse_args()
    args.evidence = args.evidence.resolve()
    inventory = json.loads(args.inventory.read_text())
    ledger = json.loads(args.output.read_text()) if args.output.exists() else {"schema": 1, "config_sha256": inventory["config_sha256"], "sites": {}}
    if ledger["config_sha256"] != inventory["config_sha256"]:
        raise SystemExit("Configuration changed; use a new output.")
    args.evidence.mkdir(parents=True, exist_ok=True)
    device = Device(args.serial, args.evidence)
    device.adb("shell", "svc", "power", "stayon", "true")
    device.adb("shell", "input", "keyevent", "KEYCODE_WAKEUP")
    order = {s["name"]: s["ordinal"] for s in inventory["sites"]}
    for site in inventory["sites"]:
        key = site["key"]
        if args.only and key not in args.only:
            continue
        if key in ledger["sites"] and ledger["sites"][key]["status"] != "automation_needs_review" and not args.redo:
            continue
        print(f"START {site['ordinal']:02} {site['name']}", flush=True)
        try:
            device.select(site["name"], order)
            record = device.observe_home(site["ordinal"], site["name"])
        except (RuntimeError, StopIteration, subprocess.SubprocessError, ValueError) as error:
            record = {"status": "automation_needs_review", "error_type": type(error).__name__}
            if isinstance(error, RuntimeError):
                record["reason"] = str(error)
            device.adb("shell", "input", "keyevent", "4")
        if key in ledger["sites"]:
            ledger.setdefault("attempt_history", {}).setdefault(key, []).append(ledger["sites"][key])
        ledger["sites"][key] = {"name": site["name"], **record}
        save(args.output, ledger)
        print(f"DONE  {site['ordinal']:02} {record['status']}", flush=True)


if __name__ == "__main__":
    main()
