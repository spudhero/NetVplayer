import { moduleGoldenValue } from "./module_golden_helper.mjs";

export class Spider {
    async init() {
        const concurrentHTTP = await Promise.all([
            http("https://golden.example.test/catalog", { headers: { "X-Golden": "quickjs" } }),
            http("https://golden.example.test/catalog", { headers: { "X-Golden": "quickjs" } }),
            http("https://golden.example.test/catalog", { headers: { "X-Golden": "quickjs" } }),
        ]);
        const concurrentHTTPStress = await Promise.all(
            Array.from({ length: 32 }, () => http("https://golden.example.test/catalog", {
                headers: { "X-Golden": "quickjs" },
            }))
        );
        const fetchAsyncCancelled = await fetch("https://golden.example.test/cancel")
            .then(() => false)
            .catch(() => true);
        const fetchQueueCancelled = await Promise.all(
            Array.from({ length: 8 }, () => fetch("https://golden.example.test/cancel")
                .then(() => false)
                .catch(() => true))
        );
        const httpResponse = req("https://golden.example.test/catalog", {
            headers: { "X-Golden": "quickjs" },
            buffer: 2,
        });
        const httpSignedBytes = req("https://golden.example.test/bytes", { buffer: 1 });
        const httpRawBytes = req("https://golden.example.test/raw-bytes", { buffer: 3 });
        const httpUnsupportedBuffer = req("https://golden.example.test/unsupported-buffer", { buffer: 4 });
        const httpError = req("https://golden.example.test/failure");
        const httpCallbackError = await new Promise((resolve) => {
            http("https://golden.example.test/failure", { complete: resolve });
        });
        const httpAsyncError = await http("https://golden.example.test/failure");
        const httpSyncViaHTTP = http("https://golden.example.test/catalog", {
            async: false,
            headers: { "X-Golden": "quickjs" },
        });
        const fetchFailureRejects = await fetch("https://golden.example.test/failure")
            .then(() => false)
            .catch(() => true);
        const html = "<section><article class='card'><a href='/one'><span class='title'>One</span></a></article><article class='card'><a href='/two'><span class='title'>Two</span></a></article></section>";
        const cipher = aesX(
            "AES/CBC/PKCS5",
            true,
            "hello",
            false,
            "0123456789abcdef",
            "abcdef9876543210",
            true,
        );
        const invalidCipher = aesX(
            "AES/GCM/NoPadding",
            true,
            "hello",
            false,
            "0123456789abcdef",
            null,
            true,
        );
        const invalidRSA = rsaX(
            "RSA/PKCS1",
            true,
            true,
            "hello",
            false,
            "not-a-key",
            true,
        );
        local.set("golden", "token", "persisted");
        const token = local.get("golden", "token");
        local.delete("golden", "deleted");
        const timer = await new Promise((resolve) => {
            let cancelledTimerFired = false;
            const cancelled = setTimeout(() => { cancelledTimerFired = true; }, 5);
            clearTimeout(cancelled);
            let cancelledIntervalFired = false;
            const cancelledInterval = setInterval(() => { cancelledIntervalFired = true; }, 1);
            clearTimeout(cancelledInterval);
            let intervalTicks = 0;
            const interval = setInterval(() => {
                intervalTicks += 1;
                if (intervalTicks !== 3) return;
                clearInterval(interval);
                setTimeout((left, right) => resolve({
                    cancelled_fired: cancelledTimerFired,
                    cancelled_interval_fired: cancelledIntervalFired,
                    interval_ticks: intervalTicks,
                    argument_sum: left + right,
                }), 5, 2, 3);
            }, 2);
        });
        const timerStressCallbacks = await new Promise((resolve) => {
            const expected = 32;
            let fired = 0;
            for (let index = 0; index < expected; index += 1) {
                setTimeout(() => {
                    fired += 1;
                    if (fired === expected) resolve(fired);
                }, 0);
            }
        });
        setInterval(() => {}, 1000);
        const proxy = {
            port: getPort(),
            url: getProxy(true),
            external_url: getProxy(false),
            js: js2Proxy(false, 1, "golden", "https://golden.example.test/video?token=a&b=c", {
                "X-Test": "a b",
            }),
            dynamic_js: js2Proxy(true, 1, "golden", "https://golden.example.test/video?token=a&b=c", {
                "X-Test": "a b",
            }),
        };
        const text = {
            simplified_to_traditional: s2t("简体中文"),
            traditional_to_simplified: t2s("繁體中文"),
        };
        const asyncGeneratorValues = [];
        for await (const value of this.asyncValues()) asyncGeneratorValues.push(value);
        const bigint = (2n ** 64n).toString();
        const moduleURL = "https://golden.example.test/module.mjs";
        const moduleHTTP = Module.fetch(moduleURL);
        const moduleResources = {
            http: moduleHTTP === "remote-module",
            http_repeated: Module.fetch(moduleURL) === moduleHTTP,
            asset: Module.fetch("assets://module_resource_asset.mjs").includes("assets://module-resource"),
            lib: Module.fetch("lib/module_resource_lib.mjs").includes("lib/module-resource"),
            missing: Module.fetch("assets://missing-module.mjs") === "",
            relative_denied: Module.fetch("./module_golden_helper.mjs") === null,
            unsupported: Module.fetch("fixture.js") === null,
            remote_denied: (() => {
                try {
                    Module.fetch("data:text/javascript,export default 1");
                    return false;
                } catch (_) {
                    return true;
                }
            })(),
            uppercase_http: Module.fetch("HTTP://golden.example.test/module.mjs") === null,
            uppercase_assets: Module.fetch("ASSETS://module_resource_asset.mjs") === null,
            http_prefix_invalid: Module.fetch("http-invalid") === "",
            assets_prefix_invalid: Module.fetch("assets-invalid") === "",
        };
        Module.clear();
        moduleResources.http_after_clear = Module.fetch(moduleURL) === "remote-module";
        const moduleLRUValues = [];
        for (let index = 0; index < 51; index += 1) {
            moduleLRUValues.push(Module.fetch(`https://golden.example.test/module-lru-${index}.mjs`));
        }
        moduleResources.lru_values = moduleLRUValues.every((value, index) => value === `module-lru-${index}`);
        moduleResources.lru_eviction = Module.fetch("https://golden.example.test/module-lru-0.mjs") === "module-lru-0";
        const baseURL = "https://example.test/a/b/page?old=1#frag";
        return {
            http: {
                code: httpResponse.code,
                content_base64: httpResponse.content,
                header: httpResponse.headers["X-Golden-Response"] || "",
                multi_header: httpResponse.headers["X-Golden-Multi"] || [],
            },
            http_buffer_1: httpSignedBytes.content,
            http_buffer_3: {
                is_uint8_array: httpRawBytes.content instanceof Uint8Array,
                bytes: Array.from(httpRawBytes.content),
            },
            http_buffer_4_has_content: Object.prototype.hasOwnProperty.call(httpUnsupportedBuffer, "content"),
            http_error: httpError,
            http_callback_error: httpCallbackError,
            http_async_error: httpAsyncError,
            http_sync_via_http_code: httpSyncViaHTTP.code,
            http_async_concurrent_codes: concurrentHTTP.map((response) => response.code),
            http_async_stress_count: concurrentHTTPStress.filter((response) => response.code === 200).length,
            fetch_async_cancelled: fetchAsyncCancelled,
            fetch_queue_cancelled_count: fetchQueueCancelled.filter(Boolean).length,
            fetch_failure_rejects: fetchFailureRejects,
            jsp: {
                cards: jsp.pdfa(html, "article.card").length,
                title: jsp.pdfh(html, "article.card&&.title&&Text"),
                link: jsp.pd(html, "article.card:eq(-1)&&a&&href", "https://golden.example.test/catalog/"),
                list: jsp.pdfl(html, ".title&&Text", "a&&href", "https://golden.example.test/catalog/"),
            },
            crypto: { cipher, invalid_cipher: invalidCipher, invalid_rsa: invalidRSA },
            local: { token },
            timer: { ...timer, stress_callbacks: timerStressCallbacks },
            url: {
                relative: joinUrl(baseURL, "../detail?new=2#next"),
                query: joinUrl(baseURL, "?new=2#next"),
                fragment: joinUrl(baseURL, "#next"),
                empty: joinUrl(baseURL, ""),
                network: joinUrl(baseURL, "//cdn.example.test/a/../media.ts"),
                absolute: joinUrl(baseURL, "https://cdn.example.test/a/../media.ts"),
                double_slash: joinUrl(baseURL, "/a//b/./c"),
                above_root: joinUrl(baseURL, "../../../../x"),
            },
            proxy,
            text,
            async_generator: {
                values: asyncGeneratorValues,
                sum: asyncGeneratorValues.reduce((total, value) => total + value, 0),
            },
            bigint,
            module: {
                loads: moduleGoldenValue(),
                repeated: moduleGoldenValue(),
                resources: moduleResources,
            },
        };
    }

    async *asyncValues() {
        yield 1;
        await Promise.resolve();
        yield 2;
    }

    proxy(parameters) {
        if (parameters?.mode === "oversize") {
            return {
                code: 200,
                content_type: "application/octet-stream",
                body: [new Uint8Array(64), new Uint8Array([1])],
            };
        }
        if (parameters?.mode === "stream") {
            return {
                code: 200,
                mime: "application/octet-stream",
                headers: { "X-Proxy": "stream" },
                body: [new Uint8Array([3, 4]), "xy"],
            };
        }
        if (parameters?.mode === "buffer-base64") {
            return {
                code: 201,
                mime: "application/octet-stream",
                buffer: 2,
                content: "AAEC/w==",
                headers: { "X-Proxy": "buffer-2" },
            };
        }
        if (parameters?.mode === "buffer-text") {
            return {
                code: 200,
                mime: "text/plain; charset=utf-8",
                buffer: 1,
                content: "你好",
                headers: { "X-Proxy": "buffer-text" },
            };
        }
        if (parameters?.mode === "gzip") {
            return {
                code: 206,
                mime: "application/gzip",
                buffer: 2,
                content: "H4sIAAAAAAACA0tMSgYAwkEkNQMAAAA=",
                headers: { "Content-Encoding": "gzip", "X-Proxy": "gzip" },
            };
        }
        if (parameters?.mode === "gzip-stream") {
            return {
                code: 206,
                mime: "application/gzip",
                headers: { "Content-Encoding": "gzip", "X-Proxy": "gzip-stream" },
                body: this.gzipStreamBody(),
            };
        }
        if (parameters?.mode === "stream-stress") {
            return {
                code: 200,
                mime: "application/octet-stream",
                headers: { "X-Proxy": "stream-stress" },
                body: this.streamStressBody(),
            };
        }
        return [206, "application/octet-stream", new Uint8Array([0, 1, 2, 255]), { "Accept-Ranges": "bytes" }, true];
    }

    async *streamStressBody() {
        for (let index = 0; index < 32; index += 1) {
            yield Uint8Array.from([index, index ^ 0xff]);
        }
    }

    async *gzipStreamBody() {
        yield Uint8Array.from([31, 139, 8, 0, 0, 0, 0, 0]);
        yield Uint8Array.from([2, 3, 75, 76, 74, 6, 0, 194]);
        yield Uint8Array.from([65, 36, 53, 3, 0, 0, 0]);
    }

    destroy() {}
}
