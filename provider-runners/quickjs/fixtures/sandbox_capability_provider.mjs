import * as std from "std";

export class Spider {
    init() {
        const asset = Module.fetch("assets://module_resource_asset.mjs");
        const lib = Module.fetch("lib/module_resource_lib.mjs");
        const missing = Module.fetch("assets://missing-module.mjs");
        const unsupported = Module.fetch("fixture.js");
        const remoteURL = std.getenv("NETVPLAYER_PROVIDER_HTTP_FIXTURE_URL") || "";
        const remote = remoteURL ? Module.fetch(remoteURL) : "";
        const legacy = local.get("sandbox", "legacy");
        local.set("sandbox", "token", "persisted");
        const token = local.get("sandbox", "token");
        local.delete("sandbox", "token");
        return {
            module: {
                asset: asset.includes("assets://module-resource"),
                lib: lib.includes("lib/module-resource"),
                missing: missing === "",
                unsupported: unsupported === null,
                http: remote === "sandbox-http-module",
            },
            local: { legacy, token },
            text: {
                s2t: s2t("简体中文"),
                t2s: t2s("繁體中文"),
            },
        };
    }

    localProxy() {
        return [
            206,
            "application/octet-stream",
            new Uint8Array([0, 1, 2, 255]),
            { "X-Sandbox-Proxy": "quickjs" },
            true,
        ];
    }

    destroy() {}
}
