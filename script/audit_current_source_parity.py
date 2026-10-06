#!/usr/bin/env python3
"""Resume real catalog/player probes for every site in a saved user configuration.

Raw source URLs and diagnostic logs stay in a private local evidence directory.
The shareable ledger records probe coverage, never claims GUI playback success.
Build the Swift tests before running; this runner deliberately uses --skip-build.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
from datetime import datetime, timedelta

ROOT = Path(__file__).resolve().parents[1]
TEST = "testRealFtyChannelPipelineAuditWhenEnabled"


def now():
    return datetime.now().astimezone().isoformat(timespec="seconds")


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False) as file:
        json.dump(value, file, ensure_ascii=False, indent=2)
        file.write("\n")
        temporary = Path(file.name)
    temporary.replace(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--configs", type=Path, default=Path.home() / "Library/Application Support/NetVplayer/configs.json")
    parser.add_argument("--config-id", type=int, default=1)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--phase", choices=["catalog", "player"], default="catalog")
    parser.add_argument("--only", action="append", default=[])
    parser.add_argument("--type", dest="category", help="Exact category name or id for a targeted replay")
    parser.add_argument("--keyword", help="Title to search for before detail/player probes")
    parser.add_argument("--vod-id", help="Exact provider video id for a repeatable detail/player replay")
    parser.add_argument("--page", type=int, default=1)
    parser.add_argument("--flag", help="Exact playback route name")
    parser.add_argument("--all-flags", action="store_true", help="Probe each loaded route, unless --flag selects one")
    parser.add_argument("--episode-start", type=int, default=1, help="One-based episode position within each route")
    parser.add_argument("--episode-count", type=int, choices=range(1, 101), default=1)
    parser.add_argument("--sample-start", type=int, default=1, help="One-based title position within the selected page")
    parser.add_argument("--sample-count", type=int, choices=range(1, 6), default=3)
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--redo", action="store_true")
    args = parser.parse_args()
    if min(args.page, args.episode_start, args.sample_start) < 1:
        parser.error("Page, episode start and sample start must be positive.")
    args.evidence = args.evidence.resolve()
    saved = next(c for c in json.loads(args.configs.read_text()) if c["id"] == args.config_id)
    config = json.loads(saved["json"]) if isinstance(saved["json"], str) else saved["json"]
    digest = hashlib.sha256(json.dumps(config, sort_keys=True).encode()).hexdigest()
    args.evidence.mkdir(parents=True, exist_ok=True, mode=0o700)
    ledger = json.loads(args.output.read_text()) if args.output.exists() else {
        "schema": 1, "created_at": now(), "config_sha256": digest,
        "scope": "Inventory from the saved configuration; probes reload its live URL. First-page category attempts stop at the first error per site. Separate GUI and Android evidence required.",
        "sites": [{"ordinal": i, "key": s["key"], "name": s["name"], "catalog": {"status": "pending"},
                   "player": {"status": "pending"}, "android": {"status": "pending"},
                   "mac_gui": {"status": "pending"}} for i, s in enumerate(config["sites"], 1)],
    }
    if ledger["config_sha256"] != digest:
        raise SystemExit("Configuration changed: choose a new output ledger instead of mixing snapshots.")
    save(args.output, ledger)
    for site_key in [s["key"] for s in ledger["sites"]]:
        ledger = json.loads(args.output.read_text())
        site = next(s for s in ledger["sites"] if s["key"] == site_key)
        if args.only and site["key"] not in args.only:
            continue
        previous = site[args.phase]
        not_before = site.get("probe_not_before")
        if not_before and datetime.now().astimezone() < datetime.fromisoformat(not_before):
            print(f"SKIP  {site['ordinal']:02} {site['name']} rate limit cooldown until {not_before}", flush=True)
            continue
        if previous["status"] not in ("pending", "running", "interrupted") and not args.redo:
            continue
        attempt = datetime.now().astimezone().strftime("%Y%m%dT%H%M%S%f")
        log = args.evidence / f"mac-{site['ordinal']:02}-{args.phase}-{attempt}.log"
        env = dict(os.environ, NETVPLAYER_REAL_CHANNEL_AUDIT="1",
                   NETVPLAYER_REAL_SOURCE_URL=saved["url"],
                   NETVPLAYER_REAL_CHANNEL_AUDIT_SITE=site["key"],
                   NETVPLAYER_REAL_CHANNEL_AUDIT_STAGE="category" if args.phase == "catalog" else "player",
                   NETVPLAYER_REAL_CHANNEL_AUDIT_ALL_TYPES="1" if args.phase == "catalog" else "0",
                   NETVPLAYER_REAL_CHANNEL_AUDIT_ALL_FLAGS="1" if args.all_flags else "0",
                   NETVPLAYER_REAL_CHANNEL_AUDIT_PAGE=str(args.page),
                   NETVPLAYER_REAL_CHANNEL_AUDIT_EPISODE_START=str(args.episode_start),
                   NETVPLAYER_REAL_CHANNEL_AUDIT_EPISODE_COUNT=str(args.episode_count),
                   NETVPLAYER_REAL_CHANNEL_AUDIT_SAMPLE_START=str(args.sample_start),
                   NETVPLAYER_REAL_CHANNEL_AUDIT_SAMPLE_COUNT=str(args.sample_count),
                   NETVPLAYER_REAL_CHANNEL_AUDIT_MEDIA_PROBE="1" if args.phase == "player" else "0")
        for suffix, value in (("TYPE", args.category), ("KEYWORD", args.keyword), ("FLAG", args.flag), ("VOD_ID", args.vod_id)):
            env.pop(f"NETVPLAYER_REAL_CHANNEL_AUDIT_{suffix}", None)
            if value:
                env[f"NETVPLAYER_REAL_CHANNEL_AUDIT_{suffix}"] = value
        # Search/input-only sites need a title rather than an invented homepage card.
        if args.phase == "player" and not args.keyword and not args.vod_id and site["key"] in {"seed", "ZPan", "YpanSo", "BpanSo", "抠搜", "UC"}:
            env["NETVPLAYER_REAL_CHANNEL_AUDIT_KEYWORD"] = "仙逆"
        if previous["status"] != "pending":
            site.setdefault("attempt_history", {}).setdefault(args.phase, []).append(previous)
        revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        dirty = bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True).strip())
        record = {"status": "running", "started_at": now(), "evidence": str(log),
                  "revision": revision, "working_tree_modified": dirty,
                  "selection": {"category": args.category, "keyword": env.get("NETVPLAYER_REAL_CHANNEL_AUDIT_KEYWORD"), "flag": args.flag,
                                "vod_id_sha256": hashlib.sha256(args.vod_id.encode()).hexdigest() if args.vod_id else None,
                                "page": args.page, "all_flags": args.all_flags,
                                "episode_start": args.episode_start, "episode_count": args.episode_count,
                                "sample_start": args.sample_start, "sample_count": args.sample_count}}
        site[args.phase] = record
        save(args.output, ledger)
        print(f"START {site['ordinal']:02} {site['name']} {args.phase}", flush=True)
        with log.open("w") as output:
            os.chmod(log, 0o600)
            process = subprocess.Popen(["swift", "test", "--package-path", str(ROOT / "NetVplayer"),
                                        "--disable-sandbox", "--no-parallel", "--skip-build", "--filter", TEST],
                                       cwd=ROOT, env=env, stdout=output, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            try:
                code = process.wait(timeout=args.timeout)
                record["status"] = "checked" if code == 0 else "needs_review"
                record["exit_code"] = code
            except (subprocess.TimeoutExpired, KeyboardInterrupt) as error:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                record["status"] = "timeout" if isinstance(error, subprocess.TimeoutExpired) else "interrupted"
        raw = log.read_text(errors="replace")
        # Only copy fixed probe fields; do not persist raw errors, headers or URLs.
        lines = [line.split("[REAL_CHANNEL_AUDIT] ", 1)[1] for line in raw.splitlines() if "[REAL_CHANNEL_AUDIT] " in line]
        record["observations"] = [re.sub(r"https?://[^\s\"']+", "<redacted-url>", line.split(" urlPrefix=", 1)[0]) for line in lines
                                  if "rawError=" not in line and " status=invalid " not in line]
        record["issues"] = []
        for line in raw.splitlines():
            if any(marker in line for marker in ("首页分类和影片均为空", "分类 ", "详情没有可播放剧集", "媒体探测失败")):
                if "[REAL_CHANNEL_AUDIT]" not in line and not re.search(r"https?://|[Cc]ookie|[Tt]oken|url=", line):
                    record["issues"].append(line.strip()[:300])
        if not lines and record["status"] == "checked":
            record["status"] = "no_evidence"
        if any(" status=invalid " in line for line in lines):
            record["status"] = "invalid_configuration"
        if any("stage=rate-limited status=429" in line for line in lines):
            record["status"] = "rate_limited"
            record["retry_not_before"] = (datetime.now().astimezone() + timedelta(minutes=5)).isoformat(timespec="seconds")
        record["finished_at"] = now()
        ledger["updated_at"] = now()
        # Reload other phases so manual Android / GUI annotations are retained.
        current = json.loads(args.output.read_text())
        current_site = next(s for s in current["sites"] if s["key"] == site["key"])
        current_site[args.phase] = record
        if record["status"] == "rate_limited":
            current_site["probe_not_before"] = record["retry_not_before"]
        else:
            current_site.pop("probe_not_before", None)
        current["updated_at"] = ledger["updated_at"]
        save(args.output, current)
        ledger = current
        print(f"DONE  {site['ordinal']:02} {site['name']} {record['status']} observations={len(record['observations'])}", flush=True)
        if record["status"] == "interrupted":
            break


if __name__ == "__main__":
    main()
