#!/usr/bin/env python3
"""Record each visible FongMi detail route without crediting automatic fallback.

Start on the intended detail screen. Screenshots still need visual review; an
advancing MediaSession alone does not establish that the intended program plays.
"""

import argparse
from datetime import datetime
import json
from pathlib import Path
import re
import time

from audit_fongmi_current_catalog import Device


def strip(tree):
    return next(n for n in tree.iter("node") if n.get("resource-id", "").endswith(":id/flag"))


def route_names(tree):
    return [n.get("text") for n in strip(tree).iter("node") if n.get("text")]


def slide(device, tree, forward):
    x1, y1, x2, y2 = device.bounds(strip(tree))
    margin = (x2 - x1) // 8
    start, end = (x2 - margin, x1 + margin) if forward else (x1 + margin, x2 - margin)
    device.adb("shell", "input", "swipe", str(start), str((y1+y2)//2), str(end), str((y1+y2)//2), "400")


def snapshot(device, label):
    tree, xml = device.dump(label)
    flags = [n.get("text") for n in strip(tree).iter("node") if n.get("selected") == "true"]
    site = next((n.get("text") for n in tree.iter("node") if n.get("text", "").startswith("站源：")), "")
    episodes = next((n for n in tree.iter("node") if n.get("resource-id", "").endswith(":id/episode")), None)
    selected_episodes = [n.get("text") for n in episodes.iter("node") if n.get("selected") == "true"] if episodes is not None else []
    media = device.adb("shell", "dumpsys", "media_session").decode(errors="replace")
    matches = re.findall(r"PlaybackState \{state=(\d+), position=(\d+), buffered position=(\d+)", media)
    image = device.evidence / (label + ".png")
    image.write_bytes(device.adb("exec-out", "screencap", "-p"))
    return {"site": site, "selected_flags": flags, "selected_episodes": selected_episodes, "media": [list(map(int, m)) for m in matches],
            "xml": xml, "screenshot": str(image), "observed_at": datetime.now().astimezone().isoformat(timespec="seconds")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--site", required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--only", action="append", default=[])
    parser.add_argument("--episode", help="Exact visible episode to select and retain during the observation")
    parser.add_argument("--seconds", type=int, default=12)
    args = parser.parse_args()
    args.evidence.mkdir(parents=True, exist_ok=True, mode=0o700)
    device = Device(args.serial, args.evidence)
    device.adb("shell", "svc", "power", "stayon", "true")
    device.adb("shell", "input", "keyevent", "KEYCODE_WAKEUP")
    tree, _ = device.dump("inventory-start")
    if not any(n.get("text") == "站源：" + args.site for n in tree.iter("node")):
        raise SystemExit("Open the intended site's detail before running this audit.")
    # Rewind and then discover the entire horizontal strip from fresh UI bounds.
    previous = None
    for _ in range(20):
        names = route_names(tree)
        if names == previous:
            break
        previous = names
        slide(device, tree, False)
        tree, _ = device.dump("inventory-rewind")
    routes, previous = [], None
    for _ in range(20):
        names = route_names(tree)
        routes.extend(name for name in names if name not in routes)
        if names == previous:
            break
        previous = names
        slide(device, tree, True)
        tree, _ = device.dump("inventory-forward")
    (args.evidence / "routes.json").write_text(json.dumps(routes, ensure_ascii=False, indent=2))
    print("ROUTES " + json.dumps(routes, ensure_ascii=False), flush=True)
    for ordinal, target in enumerate(routes):
        if args.only and target not in args.only:
            continue
        label = f"route-{ordinal+1:02}-{int(time.time())}"
        for _ in range(24):
            tree, _ = device.dump(label + "-select")
            if not any(n.get("text") == "站源：" + args.site for n in tree.iter("node")):
                raise SystemExit("The app switched sites; reopen the intended detail and resume with --only.")
            node = next((n for n in strip(tree).iter("node") if n.get("text") == target), None)
            if node is not None and device.bounds(node)[2] - device.bounds(node)[0] >= 48:
                device.tap(node)
                break
            names = route_names(tree)
            slide(device, tree, routes.index(names[0]) <= ordinal)
        else:
            raise SystemExit("Route selection did not converge: " + target)
        tree, _ = device.dump(label + "-episodes")
        # Prefer the currently visible HD/mandarin entry over an older TC entry.
        episodes = next((n for n in tree.iter("node") if n.get("resource-id", "").endswith(":id/episode")), None)
        preferred = next((n for name in ([args.episode] if args.episode else ["HD", "国语中字", "HD国语", "HD中字", "正片", "高清"])
                          for n in episodes.iter("node") if n.get("text") == name), None) if episodes is not None else None
        if args.episode and preferred is None:
            raise SystemExit("Requested episode is not visible on this route: " + args.episode)
        if preferred is None and episodes is not None:
            selected = next((n for n in episodes.iter("node") if n.get("text") and n.get("selected") == "true"), None)
            preferred = selected if selected is not None else next((n for n in episodes.iter("node") if n.get("text")), None)
        if preferred is not None and preferred.get("selected") != "true":
            device.tap(preferred)
        requested_episode = preferred.get("text") if preferred is not None else None
        time.sleep(max(1, min(args.seconds, 30)))
        device.adb("shell", "input", "keyevent", "KEYCODE_MEDIA_PAUSE")
        before = snapshot(device, label + "-before")
        same_route = before["site"] == "站源：" + args.site and before["selected_flags"] == [target]
        after = None
        if same_route:
            device.adb("shell", "input", "keyevent", "KEYCODE_MEDIA_PLAY")
            time.sleep(8)
            device.adb("shell", "input", "keyevent", "KEYCODE_MEDIA_PAUSE")
            after = snapshot(device, label + "-after")
            same_route = after["site"] == before["site"] and after["selected_flags"] == [target]
        episode_confirmed = bool(requested_episode and before["selected_episodes"] == [requested_episode] and after
                                 and after["selected_episodes"] == before["selected_episodes"])
        advanced = bool(same_route and episode_confirmed and before["media"] and after and after["media"]
                        and after["media"][0][1] > before["media"][0][1] + 1000
                        and after["media"][0][0] == 2)
        record = {"route": target, "requested_episode": requested_episode, "before": before, "after": after,
                  "status": "progress_observed_frame_pending" if advanced else
                  "automatic_fallback" if not same_route else
                  "automatic_episode_change" if before["selected_episodes"] and not episode_confirmed else
                  "no_selected_episode" if not episode_confirmed else "no_progress"}
        with (args.evidence / "attempts.jsonl").open("a") as output:
            output.write(json.dumps(record, ensure_ascii=False) + "\n")
        for path in args.evidence.iterdir():
            if path.is_file():
                path.chmod(0o600)
        print(json.dumps({"route": target, "status": record["status"], "selected": before["selected_flags"]}, ensure_ascii=False), flush=True)
        if before["site"] != "站源：" + args.site:
            break


if __name__ == "__main__":
    main()
