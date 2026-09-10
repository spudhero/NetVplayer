#!/usr/bin/env python3

from __future__ import annotations

from pathlib import Path
import unittest


class QuickJSProviderRunnerContractTests(unittest.TestCase):
    def test_runner_declares_core_lifecycle_and_pure_host_capabilities(self) -> None:
        source = Path("provider-runners/quickjs/provider_runner.mjs").read_text(encoding="utf-8")
        for operation in ("handshake", "health", "init", "home", "category", "detail", "search", "player", "live", "manual_video_check", "is_video_format", "proxy", "action", "destroy"):
            self.assertIn(operation, source)
        self.assertIn('runtime: "quickjs"', source)
        self.assertIn('"core-lifecycle"', source)
        self.assertIn("installCoreHostAPI(", source)
        self.assertIn("NETVPLAYER_PROVIDER_HOST_CAPABILITIES", source)
        for symbol in ("localProxy", "proxyValue", "proxyBody", "body_base64", "buffer", "base64DecodeBytes", "Module.fetch HTTP requires the http capability", "NETVPLAYER_MAX_PROXY_BYTES"):
            self.assertIn(symbol, source)

    def test_core_host_api_is_capability_scoped(self) -> None:
        source = Path("provider-runners/quickjs/host_api.mjs").read_text(encoding="utf-8")
        for symbol in (
            "base64Encode",
            "base64Decode",
            "base64DecodeBytes",
            "md5X",
            "joinUrl",
            "installHTTPHostAPI",
            "host_request",
            "globalThis._http",
            "fetch",
            "installJSPHostAPI",
            "globalThis.jsp",
            "pdfa",
            "pdfh",
            "pd",
            "pdfl",
            "console.log",
            "aesX",
            "rsaX",
            "globalThis.local",
            "installCryptoHostAPI",
            "installPersistenceHostAPI",
            "installTimerHostAPI",
            "globalThis.setTimeout",
            "globalThis.clearTimeout",
            "globalThis.setInterval",
            "globalThis.clearInterval",
            "clearInstalledTimers",
            "installTextHostAPI",
            "globalThis.s2t",
            "globalThis.t2s",
            "installLocalProxyHostAPI",
            "globalThis.getPort",
            "globalThis.getProxy",
            "globalThis.js2Proxy",
            "queuedAsyncHostRequests",
            "maximumAsyncHostRequests = 1",
            "pumpAsyncHostRequests",
        ):
            self.assertIn(symbol, source)
        self.assertIn("enabledCapabilities", source)
        self.assertIn('enabled.has("http")', source)
        self.assertIn('enabled.has("jsp")', source)
        self.assertIn('enabled.has("crypto")', source)
        self.assertIn('enabled.has("persistence")', source)
        self.assertIn('enabled.has("timer")', source)
        self.assertIn('enabled.has("text")', source)
        self.assertIn('enabled.has("local_proxy")', source)

    def test_runner_restricts_module_to_signed_package_root(self) -> None:
        source = Path("provider-runners/quickjs/provider_runner.mjs").read_text(encoding="utf-8")
        self.assertIn("isInside(providerPath, packageRoot)", source)
        self.assertIn("Provider entrypoint must be a package-local", source)
        self.assertIn("validateModuleGraph(providerPath)", source)
        self.assertIn("installModuleHostAPI", source)
        self.assertIn("globalThis.Module", source)
        self.assertIn("assets://", source)
        self.assertIn("moduleSourceCache", source)
        self.assertIn("maximumModuleSourceCacheEntries = 50", source)
        self.assertIn("moduleSourceCache.delete(moduleSourceCache.keys().next().value)", source)
        self.assertIn("Remote or absolute JavaScript import is forbidden", source)


if __name__ == "__main__":
    unittest.main()
