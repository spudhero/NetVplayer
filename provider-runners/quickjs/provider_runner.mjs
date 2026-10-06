import * as std from "std";
import * as os from "os";
import { base64DecodeBytes, base64Encode, clearInstalledTimers, installCoreHostAPI, nextInputLine } from "./host_api.mjs";

const protocol = 1;
const argumentsList = scriptArgs;
const providerArgumentIndex = argumentsList.indexOf("--provider");
const providerPath = providerArgumentIndex >= 0 ? argumentsList[providerArgumentIndex + 1] : "";
const classArgumentIndex = argumentsList.indexOf("--class");
const className = classArgumentIndex >= 0 ? argumentsList[classArgumentIndex + 1] : null;
const providerID = std.getenv("NETVPLAYER_PROVIDER_ID") || "quickjs-provider";
const configuredMaximumProxyBytes = Number(std.getenv("NETVPLAYER_MAX_PROXY_BYTES") || 32 * 1024 * 1024);
const maximumProxyBytes = Number.isFinite(configuredMaximumProxyBytes) && configuredMaximumProxyBytes > 0
    ? configuredMaximumProxyBytes
    : 32 * 1024 * 1024;
const requestedHostCapabilities = (std.getenv("NETVPLAYER_PROVIDER_HOST_CAPABILITIES") || "")
    .split(",")
    .map((value) => value.trim())
    .filter(Boolean);
const hostCapabilities = installCoreHostAPI(requestedHostCapabilities);
const capabilities = ["core-lifecycle", ...hostCapabilities.filter((value) => value !== "core-lifecycle")];

function realPath(value) {
    const resolved = os.realpath(value);
    const path = Array.isArray(resolved) ? resolved[0] : resolved;
    return typeof path === "string" ? path : null;
}

const packageRoot = realPath(std.getenv("NETVPLAYER_PROVIDER_ROOT") || ".");

function safeMessage(value) {
    return String(value)
        .replace(/https?:\/\/[^\s"'<>]+/g, "<redacted-url>")
        .replace(/(cookie|authorization|proxy-authorization|x-api-key)\s*:\s*[^\r\n]+/ig, "$1: <redacted>");
}

function isInside(candidate, root) {
    const resolvedCandidate = safeRealPath(candidate);
    const resolvedRoot = safeRealPath(root);
    return Boolean(resolvedCandidate && resolvedRoot)
        && (resolvedCandidate === resolvedRoot || resolvedCandidate.startsWith(`${resolvedRoot}/`));
}

function safeRealPath(value) {
    try {
        return realPath(value);
    } catch (_) {
        return null;
    }
}

const moduleSourceCache = new Map();
const maximumModuleSourceCacheEntries = 50;

function readModuleSource(path) {
    const cached = moduleSourceCache.get(path);
    if (cached !== undefined) {
        moduleSourceCache.delete(path);
        moduleSourceCache.set(path, cached);
        return cached;
    }
    const file = std.open(path, "r");
    if (!file) throw new Error(`Module file cannot be opened: ${path}`);
    let source;
    try {
        source = file.readAsString();
    } finally {
        file.close();
    }
    moduleSourceCache.set(path, source);
    while (moduleSourceCache.size > maximumModuleSourceCacheEntries) {
        moduleSourceCache.delete(moduleSourceCache.keys().next().value);
    }
    return source;
}

function normalizeModuleSpecifier(specifier) {
    return specifier.startsWith("assets://")
        ? `assets/${specifier.slice("assets://".length)}`
        : specifier;
}

function resolveModulePath(basePath, specifier) {
    const baseDirectory = basePath.slice(0, basePath.lastIndexOf("/"));
    const normalizedSpecifier = normalizeModuleSpecifier(specifier);
    const roots = normalizedSpecifier.startsWith("assets/") || normalizedSpecifier.startsWith("lib/")
        ? [packageRoot, `${packageRoot}/js`]
        : [baseDirectory];
    const relative = normalizedSpecifier;
    const candidates = [];
    for (const root of roots) {
        const path = normalizedSpecifier.startsWith("/") ? normalizedSpecifier : `${root}/${relative}`;
        candidates.push(path, `${path}.mjs`, `${path}.js`, `${path}/index.mjs`, `${path}/index.js`);
    }
    for (const candidate of candidates) {
        const resolved = safeRealPath(candidate);
        if (resolved && isInside(resolved, packageRoot)) return resolved;
    }
    throw new Error(`Module import is not a signed package file: ${specifier}`);
}

function moduleSpecifiers(source) {
    const specifiers = [];
    const staticImports = /\b(?:import|export)\s+(?:[\s\S]*?\s+from\s+)?["']([^"']+)["']/g;
    for (const match of source.matchAll(staticImports)) specifiers.push(match[1]);
    const dynamicImports = /\bimport\s*\(\s*(["'])([^"']+)\1\s*\)/g;
    for (const match of source.matchAll(dynamicImports)) specifiers.push(match[2]);
    if (/\bimport\s*\(\s*(?!["'])/.test(source)) {
        throw new Error("Dynamic module import must use a string literal");
    }
    return specifiers;
}

function validateModuleGraph(entryPath) {
    const pending = [entryPath];
    const visited = new Set();
    while (pending.length) {
        const current = pending.pop();
        if (visited.has(current)) continue;
        visited.add(current);
        const source = readModuleSource(current);
        for (const specifier of moduleSpecifiers(source)) {
            if (specifier === "std" || specifier === "os") continue;
            if (/^(?:https?:|data:|file:|node:)/i.test(specifier) || specifier.startsWith("/")) {
                throw new Error(`Remote or absolute JavaScript import is forbidden: ${specifier}`);
            }
            const normalizedSpecifier = normalizeModuleSpecifier(specifier);
            if (!normalizedSpecifier.startsWith(".") && !normalizedSpecifier.startsWith("assets/") && !normalizedSpecifier.startsWith("lib/")) {
                throw new Error(`Unsupported JavaScript import: ${specifier}`);
            }
            pending.push(resolveModulePath(current, specifier));
        }
    }
}

function installModuleHostAPI(entryPath) {
    if (!requestedHostCapabilities.includes("module")) return;
    globalThis.Module = Object.freeze({
        fetch(name) {
            const specifier = String(name);
            if (specifier.startsWith("http")) {
                if (!requestedHostCapabilities.includes("http")) {
                    throw new Error("Module.fetch HTTP requires the http capability");
                }
                const cached = moduleSourceCache.get(specifier);
                if (cached !== undefined) {
                    moduleSourceCache.delete(specifier);
                    moduleSourceCache.set(specifier, cached);
                    return cached;
                }
                try {
                    const result = globalThis.req(specifier, { buffer: 0 });
                    const source = typeof result.content === "string" ? result.content : "";
                    if (source) {
                        moduleSourceCache.set(specifier, source);
                        while (moduleSourceCache.size > maximumModuleSourceCacheEntries) {
                            moduleSourceCache.delete(moduleSourceCache.keys().next().value);
                        }
                    }
                    return source;
                } catch (_) {
                    return "";
                }
            }
            if (/^(?:data:|file:|node:)/i.test(specifier)) {
                throw new Error(`Remote Module.fetch is forbidden: ${specifier}`);
            }
            if (specifier.startsWith("/") || specifier.startsWith(".")) return null;
            const isPackageResource = specifier.startsWith("assets")
                || specifier.startsWith("assets/")
                || specifier.startsWith("lib/");
            if (!isPackageResource) return null;
            try {
                return readModuleSource(resolveModulePath(entryPath, specifier));
            } catch (error) {
                return "";
            }
        },
        clear() {
            moduleSourceCache.clear();
        },
    });
    hostCapabilities.push("module");
}

function ok(requestID, result) {
    return { request_id: requestID, ok: true, result, error: null };
}

function failure(requestID, code, message, diagnostic = "Error") {
    return {
        request_id: requestID,
        ok: false,
        result: null,
        error: { code, message: safeMessage(message), retryable: false, diagnostic },
    };
}

const methods = {
    init: ["init", (a) => [a.extend ?? a.ext ?? ""]],
    home: ["homeContent", (a) => [Boolean(a.filter ?? true)]],
    home_video: ["homeVideoContent", () => []],
    category: ["categoryContent", (a) => [String(a.category_id ?? a.tid ?? ""), String(a.page ?? a.pg ?? "1"), Boolean(a.filter ?? true), a.extend ?? {}]],
    detail: ["detailContent", (a) => [a.ids ?? [a.id ?? ""]]],
    search: ["searchContent", (a) => [String(a.keyword ?? a.key ?? ""), Boolean(a.quick ?? false), String(a.page ?? a.pg ?? "1")]],
    player: ["playerContent", (a) => [String(a.flag ?? ""), String(a.id ?? a.url ?? ""), a.vip_flags ?? a.vipFlags ?? []]],
    live: ["liveContent", (a) => [String(a.url ?? "")]],
    manual_video_check: ["manualVideoCheck", () => []],
    is_video_format: ["isVideoFormat", (a) => [String(a.url ?? "")]],
    proxy: ["localProxy", (a) => [a.parameters ?? a.params ?? a]],
    action: ["action", (a) => [String(a.action ?? ""), String(a.value ?? "")]],
    destroy: ["destroy", () => []],
};

function bytesFrom(value) {
    if (value instanceof Uint8Array) return value;
    if (typeof ArrayBuffer !== "undefined" && value instanceof ArrayBuffer) return new Uint8Array(value);
    return null;
}

function textBytes(value) {
    return base64DecodeBytes(base64Encode(String(value)));
}

function chunkBytes(value) {
    const bytes = bytesFrom(value);
    if (bytes) return bytes;
    if (typeof value === "number") return Uint8Array.from([value & 0xff]);
    return textBytes(value);
}

async function proxyBody(body) {
    const directBytes = bytesFrom(body);
    if (body == null || typeof body === "string" || directBytes) return [directBytes || body, Boolean(directBytes)];
    const hasAsyncIterator = typeof Symbol !== "undefined" && typeof body[Symbol.asyncIterator] === "function";
    const hasIterator = typeof Symbol !== "undefined" && typeof body[Symbol.iterator] === "function";
    if (hasAsyncIterator || hasIterator) {
        const chunks = [];
        let size = 0;
        for await (const chunk of body) {
            const bytes = chunkBytes(chunk);
            size += bytes.length;
            if (size > maximumProxyBytes) throw new Error("proxy stream exceeds the configured byte limit");
            chunks.push(bytes);
        }
        const result = new Uint8Array(size);
        let offset = 0;
        for (const chunk of chunks) {
            result.set(chunk, offset);
            offset += chunk.length;
        }
        return [result, true];
    }
    return [body, false];
}

function normalizeHeaders(headers) {
    const normalized = {};
    if (!headers || typeof headers !== "object") return normalized;
    for (const key of Object.keys(headers)) normalized[String(key)] = String(headers[key]);
    return normalized;
}

async function proxyValue(value) {
    if (Array.isArray(value)) {
        const [status = 200, contentType = null, rawBody = null, headers = {}, forceBase64 = false] = value;
        const [body, streamBody] = await proxyBody(rawBody);
        const bytes = bytesFrom(body) || streamBody;
        return {
            status_code: Number(status),
            content_type: contentType,
            headers: normalizeHeaders(headers),
            ...(body == null ? {} : ((forceBase64 || bytes)
                ? { body_base64: base64Encode(bytesFrom(body) || textBytes(body)) }
                : { body: String(body) })),
        };
    }
    if (value && typeof value === "object") {
        const payload = { ...value };
        payload.status_code = Number(payload.status_code ?? payload.code ?? 200);
        delete payload.code;
        payload.content_type = payload.content_type ?? payload.mime ?? null;
        delete payload.mime;
        const rawBody = payload.body !== undefined ? payload.body : payload.content;
        delete payload.content;
        const buffer = Number(payload.buffer ?? 0);
        delete payload.buffer;
        const bufferedBody = buffer === 2 && rawBody != null
            ? base64DecodeBytes(rawBody)
            : rawBody;
        const [body, streamBody] = await proxyBody(bufferedBody);
        payload.headers = normalizeHeaders(payload.headers);
        if (body != null) {
            const bytes = bytesFrom(body) || streamBody;
            if (bytes) {
                payload.body_base64 = base64Encode(bytesFrom(body) || textBytes(body));
                delete payload.body;
            } else {
                payload.body = String(body);
            }
        }
        return payload;
    }
    throw new Error("proxy/localProxy must return an object or CatVod response array");
}

let target;
if (!providerPath || !isInside(providerPath, packageRoot) || ![".js", ".mjs"].includes(providerPath.slice(providerPath.lastIndexOf(".")))) {
    throw new Error("Provider entrypoint must be a package-local JavaScript module");
}

try {
    installModuleHostAPI(providerPath);
    if (hostCapabilities.includes("module")) capabilities.push("module");
    validateModuleGraph(providerPath);
    const moduleValue = await import(providerPath);
    target = className ? moduleValue[className] : (moduleValue.Spider || moduleValue.default || moduleValue.spider || moduleValue);
    if (typeof target === "function") target = new target();
} catch (error) {
    throw new Error(`Provider module load failed: ${safeMessage(error.message || error)}`);
}

async function invoke(request) {
    const requestID = String(request.request_id ?? "");
    try {
        if (request.protocol !== protocol) throw new Error("unsupported protocol");
        if (request.provider_id && request.provider_id !== providerID) throw new Error("provider_id does not match the launched package");
        if (request.operation === "handshake") {
            return ok(requestID, { protocol, provider_id: providerID, runtime: "quickjs", operations: Object.keys(methods), capabilities });
        }
        if (request.operation === "health") return ok(requestID, { status: "ok", capabilities });
        if (request.operation === "cancel") return ok(requestID, { cancelled: request.arguments?.target_request_id ?? "" });
        if (request.operation === "shutdown") {
            try {
                if (typeof target.destroy === "function") await target.destroy();
            } finally {
                clearInstalledTimers();
            }
            return ok(requestID, { shutdown: true });
        }
        const descriptor = methods[request.operation];
        if (!descriptor) throw new Error(`unsupported operation: ${request.operation}`);
        let [name, makeArguments] = descriptor;
        if (request.operation === "proxy" && typeof target[name] !== "function") name = "proxy";
        if (typeof target[name] !== "function") throw new Error(`provider does not implement ${name}`);
        const value = await target[name](...makeArguments(request.arguments || {}));
        if (request.operation === "proxy") return { request_id: requestID, ok: true, result: null, proxy: await proxyValue(value), error: null };
        return ok(requestID, value === undefined ? null : value);
    } catch (error) {
        return failure(requestID, "provider_error", error.message || error, error.constructor?.name || "Error");
    }
}

let line;
while ((line = nextInputLine()) !== null) {
    let request = null;
    let response;
    try {
        request = JSON.parse(line);
        response = await invoke(request);
    } catch (error) {
        response = failure("", "invalid_request", error.message || error, error.constructor?.name || "Error");
    }
    std.out.puts(`${JSON.stringify(response)}\n`);
    std.out.flush();
    if (request?.operation === "shutdown") break;
}
clearInstalledTimers();
