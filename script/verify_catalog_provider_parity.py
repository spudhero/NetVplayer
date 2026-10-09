#!/usr/bin/env python3
"""Release gate for behavior inside extracted signed catalog packages."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
import threading
import unittest
from http.server import ThreadingHTTPServer

from test_provider_runners import RunnerProcess
from test_private_bili_script_providers import QuickJSRunnerProcess
from test_private_bili_runtime_parity import BiliParityFixture, verify_bili_process
from test_private_guard_search_provider import GuardSearchHandler
from test_private_wogg_provider import WoggHandler, assert_wogg_lifecycle
from test_private_cms_provider import CmsHandler, assert_guangying_lifecycle
from test_private_hmys_provider import HmysHandler, assert_hmys_lifecycle, FIXED_DEVICE_ID, FIXED_CLOCK

CONTRACT_REVISION = "catalog-migration-20261009"

# These adapters already return their recommendation list from homeContent.
# Verify compiled code through the packaged Runner so an older archive cannot pass.
SINGLE_HOME_PYTHON_ADAPTERS = {
    "alllive": ["Spider"], "anime1": ["Spider"], "apptt": ["Spider"],
    "auete": ["Spider"], "bili-live": ["Spider"],
    "cms": ["GuangyingSpider", "HBCms10Spider"], "dm84": ["Spider"],
    "douban-frodo": ["Spider"], "doubao": ["Spider"], "duboku": ["Spider"],
    "dytt": ["Spider"], "first-aid": ["Spider"],
    "guard-site": ["BttwooSpider", "JianpianSpider", "NewCzSpider"],
    "hbpq": ["Spider"], "ibox-appapi": ["Spider"], "kanqiu": ["Spider"],
    "libvio": ["Spider"], "music": ["Spider"], "nmvod": ["Spider"],
    "nmyswv": ["Spider"], "sixv": ["Spider"], "tangdou": ["Spider"],
    "tuxiaobei": ["Spider"], "wcai": ["Spider", "WencaiSpider"],
    "wwgz": ["Spider"], "ycyz": ["Spider"], "ygp": ["Spider"],
}


def verify_single_home_adapters(package: Path, manifest: dict, test: unittest.TestCase) -> str | None:
    if manifest["runtime"] == "python":
        mapping = json.loads((package / "provider-map.json").read_text())
        entries = {value["module"]: set() for value in mapping["keys"].values()}
        for value in list(mapping["keys"].values()) + list(mapping["apis"].values()):
            entries.setdefault(value["module"], set()).add(value["class"])
        # Class names can share a source file, but catalog module names follow provider IDs.
        targets = [(module, cls) for module, classes in entries.items() for cls in classes
                   if any(module.endswith("_" + name.replace("-", "_") + "_python") and cls in expected
                          for name, expected in SINGLE_HOME_PYTHON_ADAPTERS.items())
                   or (module.endswith(("_guard_guangying_python", "_hbcms10_python", "_wencai_hotsearch_python", "_guard_bttwoo_python", "_guard_jianpian_python", "_guard_newcz_python")))]
        test.assertEqual(len(targets), 31)
        for module, cls in sorted(targets):
            direct = dict(manifest, entrypoint=f"{module}.pyc", provider_class=cls)
            process = package_process(package, direct)
            try:
                reply = process.request("home_video")
                test.assertTrue(reply["ok"])
                test.assertEqual(reply["result"]["list"], [])
            finally:
                process.close()
        return "python-single-home-31-adapters"
    if manifest["runtime"] == "java":
        targets = [("hbpianku8", "HBPianKu8Provider"), ("app99", "App99Provider"), ("appdrama", "AppDramaProvider"),
                   ("appsx", "AppSxProvider$Boke"), ("appsx", "AppSxProvider$Gugu"), ("appsx", "AppSxProvider$Juquan"),
                   ("appgz", "AppgzProvider"), ("tingshu275", "Tingshu275Provider"), ("livegz", "LiveGzProvider")]
        for namespace, cls in targets:
            direct = dict(manifest, provider_class=f"com.netvplayer.privateprovider.{namespace}.{cls}")
            process = package_process(package, direct)
            try:
                reply = process.request("home_video")
                test.assertTrue(reply["ok"])
                test.assertEqual(reply["result"]["list"], [])
            finally:
                process.close()
        return "java-single-home-9-profiles"
    return None


def package_process(package: Path, manifest: dict, base: str = "", site: dict | None = None, java_options: list[str] | None = None):
    executable = package / manifest["runtime_executable"]
    runner = package / manifest["runner"]
    provider = package / manifest["entrypoint"]
    runtime = manifest["runtime"]
    command = [str(executable)]
    if runtime == "python":
        command += ["-B", "-I", "-S", str(runner)]
    elif runtime == "java":
        command += (java_options or []) + [f"-Dnetvplayer.bili.apiBase={base}", "-jar", str(runner)]
    elif runtime == "quickjs":
        command += ["--std", str(runner)]
    else:
        command += [str(runner)]
    command += ["--provider", str(provider), "--class", manifest.get("provider_class", "Spider")]
    factory = QuickJSRunnerProcess if runtime == "quickjs" else RunnerProcess
    process = factory(command, provider, manifest["provider_id"], package_root=package, environment_overrides={
        "NETVPLAYER_BILI_API_BASE": base,
        "NETVPLAYER_PROVIDER_HOST_CAPABILITIES": ",".join(manifest.get("host_capabilities") or []),
        "NETVPLAYER_GUARD_SEARCH_ALLOW_LOOPBACK": "1", "NETVPLAYER_WOGG_ALLOW_LOOPBACK": "1",
        "NETVPLAYER_CMS_ALLOW_LOOPBACK": "1",
    })
    if site:
        original_request = process.request
        process.request = lambda operation, arguments=None, site=site: original_request(operation, arguments, site=site)
    return process


def verify_hmys_home(package: Path, manifest: dict, test: unittest.TestCase) -> None:
    HmysHandler.requests = []
    HmysHandler.raw_responses = {}
    server = ThreadingHTTPServer(("127.0.0.1", 0), HmysHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base = f"http://127.0.0.1:{server.server_port}"
    process = package_process(
        package, dict(manifest, provider_class="com.netvplayer.privateprovider.hmys.HmysProvider"),
        java_options=["-Dnetvplayer.hmys.allowLoopback=true", f"-Dnetvplayer.hmys.catalogInitialBase={base}",
                      f"-Dnetvplayer.hmys.playbackInitialBase={base}", f"-Dnetvplayer.hmys.deviceId={FIXED_DEVICE_ID}",
                      f"-Dnetvplayer.hmys.fixedClock={FIXED_CLOCK}"],
    )
    try:
        assert_hmys_lifecycle(test, process)
    finally:
        process.close()
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


def verify_python_catalog(package: Path, manifest: dict, test: unittest.TestCase) -> list[str]:
    mapping = json.loads((package / "provider-map.json").read_text())
    test.assertEqual(mapping["keys"]["seed"]["class"], "SeedHubSpider")
    test.assertNotEqual(mapping["keys"]["seed"], mapping["keys"]["ZPan"])
    helper = package / "helpers/catalog-browser"
    test.assertTrue(helper.is_file(), "catalog browser must be a signed package asset")
    test.assertIn("helpers/catalog-browser", [asset["path"] for asset in manifest["assets"]])
    GuardSearchHandler.requests = []
    GuardSearchHandler.many = True
    server = ThreadingHTTPServer(("127.0.0.1", 0), GuardSearchHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base = f"http://127.0.0.1:{server.server_port}"
    process = package_process(package, manifest)
    try:
        for key in ("ZPan", "JPan"):
            test.assertTrue(process.request("init", {"extend": {"siteUrl": base}}, site={"key": key, "api": "csp_S_zpsGuard"})["ok"])
            home = process.request("home")["result"]
            test.assertEqual([item["type_id"] for item in home["class"]], ["all", "quark", "uc", "ali", "baidu"])
            test.assertEqual(home["filters"]["all"][0]["inputKind"], "text")
            test.assertEqual((len(home["list"]), home["total"]), (50, 62))
            page = process.request("category", {"category_id": "quark", "page": "2"})["result"]
            test.assertEqual((len(page["list"]), page["page"], page["total"]), (11, 2, 61))
            uc = process.request("category", {"category_id": "uc", "page": "1"})["result"]
            test.assertEqual([item["vod_name"] for item in uc["list"]], ["UC影片"])
        test.assertTrue(process.request("init", {"extend": {"siteUrl": base, "catalogUrl": base + "/catalog"}}, site={"key": "seed", "api": "csp_SeedhubGuard"})["ok"])
        home = process.request("home")["result"]
        test.assertEqual([item["type_name"] for item in home["class"]], ["电影", "剧集", "动漫"])
        test.assertEqual(home["list"][0]["vod_id"], "/movies/137018/@folder")
        test.assertEqual(home["filters"]["1"][1]["values"][1], {"n": "大陆台湾", "v": "64347"})
        for category_filters in home["filters"].values():
            for filter_item in category_filters:
                test.assertTrue(filter_item["values"])
                for option in filter_item["values"]:
                    test.assertEqual(set(option), {"n", "v"})
        page = process.request("category", {"category_id": "1", "page": "2", "extend": {"type": "7", "by": "score"}})["result"]
        test.assertEqual(page["page"], 2)
        test.assertEqual(GuardSearchHandler.requests[-1][1], "/catalog/categories/1/types/7/movies/")
    finally:
        process.close()
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
    WoggHandler.requests = []
    server = ThreadingHTTPServer(("127.0.0.1", 0), WoggHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    process = package_process(package, manifest, site={"key": "玩偶", "api": "csp_Wogg"})
    try:
        assert_wogg_lifecycle(test, process, f"http://127.0.0.1:{server.server_port}")
    finally:
        process.close()
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
    CmsHandler.requests = []
    CmsHandler.home_barrier = threading.Barrier(2)
    CmsHandler.home_barrier_failed = False
    server = ThreadingHTTPServer(("127.0.0.1", 0), CmsHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    process = package_process(package, manifest, site={"key": "光影", "api": "csp_T4Guard"})
    try:
        assert_guangying_lifecycle(test, process, f"http://127.0.0.1:{server.server_port}/api.php?fixture=1")
        test.assertFalse(CmsHandler.home_barrier_failed, "home categories and artwork enrichment must overlap")
    finally:
        process.close()
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
        CmsHandler.home_barrier = None
    return ["pansearch-home-filter-paging", "seedhub-catalog-filter-paging", "wogg-single-home-request", "guangying-parallel-home-enrichment"]


def verify_catalog_package(package: Path) -> dict:
    manifest = json.loads((package / "signed-manifest.json").read_text())["manifest"]
    if not str(manifest["provider_id"]).startswith("netvplayer.catalog."):
        raise ValueError("catalog behavior gate requires a catalog package")
    test = unittest.TestCase()
    try:
        for challenge in ("http", "api", "html"):
            with BiliParityFixture() as fixture:
                fixture.plain_failure = challenge
                process = package_process(package, manifest, fixture.base)
                try:
                    verify_bili_process(test, process, fixture)
                finally:
                    process.close()
        checks = ["bili-classroom-presets", "bili-single-home-request", "bili-signed-search-recovery", "bili-search-key-cache", "bili-entities", "bili-cdn-backup", "bili-dash-fallback"]
        if manifest["runtime"] == "python":
            checks += verify_python_catalog(package, manifest, test)
        single_home = verify_single_home_adapters(package, manifest, test)
        if single_home:
            checks.append(single_home)
        if manifest["runtime"] == "java":
            verify_hmys_home(package, manifest, test)
            checks.append("hmys-single-home-and-category-refresh")
    except (AssertionError, KeyError) as error:
        # Runner responses may contain signed URLs. Do not expose assertion values.
        raise ValueError("signed catalog behavior does not meet the migration contract") from None
    return {"revision": CONTRACT_REVISION, "provider_id": manifest["provider_id"], "version": manifest["version"], "checks": checks, "passed": True}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--package", type=Path, required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(verify_catalog_package(args.package.resolve()), sort_keys=True))
    except (ValueError, OSError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
