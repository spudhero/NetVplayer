import * as std from "std";
import * as os from "os";

const BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
function utf8Bytes(value) {
    const text = String(value);
    const bytes = [];
    for (let index = 0; index < text.length; index += 1) {
        const code = text.charCodeAt(index);
        if (code < 0x80) {
            bytes.push(code);
        } else if (code < 0x800) {
            bytes.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
        } else if (code >= 0xd800 && code <= 0xdbff && index + 1 < text.length) {
            const low = text.charCodeAt(++index);
            if (low >= 0xdc00 && low <= 0xdfff) {
                const point = 0x10000 + ((code - 0xd800) << 10) + low - 0xdc00;
                bytes.push(0xf0 | (point >> 18), 0x80 | ((point >> 12) & 0x3f), 0x80 | ((point >> 6) & 0x3f), 0x80 | (point & 0x3f));
            } else {
                bytes.push(0xef, 0xbf, 0xbd);
                index -= 1;
            }
        } else {
            bytes.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
        }
    }
    return bytes;
}

function decodeUTF8(bytes) {
    let text = "";
    for (let index = 0; index < bytes.length;) {
        const first = bytes[index++];
        if (first < 0x80) {
            text += String.fromCharCode(first);
        } else if ((first & 0xe0) === 0xc0 && index < bytes.length) {
            text += String.fromCharCode(((first & 0x1f) << 6) | (bytes[index++] & 0x3f));
        } else if ((first & 0xf0) === 0xe0 && index + 1 < bytes.length) {
            text += String.fromCharCode(((first & 0x0f) << 12) | ((bytes[index++] & 0x3f) << 6) | (bytes[index++] & 0x3f));
        } else if ((first & 0xf8) === 0xf0 && index + 2 < bytes.length) {
            const point = ((first & 0x07) << 18) | ((bytes[index++] & 0x3f) << 12) | ((bytes[index++] & 0x3f) << 6) | (bytes[index++] & 0x3f);
            const adjusted = point - 0x10000;
            text += String.fromCharCode(0xd800 | (adjusted >> 10), 0xdc00 | (adjusted & 0x3ff));
        } else {
            text += "\ufffd";
        }
    }
    return text;
}

export function base64Encode(value, urlSafe = false) {
    const bytes = value instanceof Uint8Array ? Array.from(value) : utf8Bytes(value);
    let output = "";
    for (let index = 0; index < bytes.length; index += 3) {
        const first = bytes[index];
        const second = index + 1 < bytes.length ? bytes[index + 1] : 0;
        const third = index + 2 < bytes.length ? bytes[index + 2] : 0;
        output += BASE64_ALPHABET[first >> 2];
        output += BASE64_ALPHABET[((first & 3) << 4) | (second >> 4)];
        output += index + 1 < bytes.length ? BASE64_ALPHABET[((second & 15) << 2) | (third >> 6)] : "=";
        output += index + 2 < bytes.length ? BASE64_ALPHABET[third & 63] : "=";
    }
    return urlSafe ? output.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "") : output;
}

export function base64Decode(value, urlSafe = false) {
    return decodeUTF8(Array.from(base64DecodeBytes(value, urlSafe)));
}

export function base64DecodeBytes(value, urlSafe = false) {
    let input = String(value).replace(/\s+/g, "");
    if (urlSafe) input = input.replace(/-/g, "+").replace(/_/g, "/");
    while (input.length % 4) input += "=";
    const bytes = [];
    for (let index = 0; index < input.length; index += 4) {
        const first = BASE64_ALPHABET.indexOf(input[index]);
        const second = BASE64_ALPHABET.indexOf(input[index + 1]);
        const third = input[index + 2] === "=" ? 0 : BASE64_ALPHABET.indexOf(input[index + 2]);
        const fourth = input[index + 3] === "=" ? 0 : BASE64_ALPHABET.indexOf(input[index + 3]);
        if (first < 0 || second < 0 || third < 0 || fourth < 0) throw new Error("invalid base64 input");
        bytes.push((first << 2) | (second >> 4));
        if (input[index + 2] !== "=") bytes.push(((second & 15) << 4) | (third >> 2));
        if (input[index + 3] !== "=") bytes.push(((third & 3) << 6) | fourth);
    }
    return Uint8Array.from(bytes);
}

function leftRotate(value, amount) {
    return (value << amount) | (value >>> (32 - amount));
}

export function md5X(value) {
    const bytes = utf8Bytes(value);
    const bitLength = bytes.length * 8;
    bytes.push(0x80);
    while (bytes.length % 64 !== 56) bytes.push(0);
    for (let index = 0; index < 8; index += 1) bytes.push((bitLength / (2 ** (8 * index))) & 0xff);

    let a0 = 0x67452301;
    let b0 = 0xefcdab89;
    let c0 = 0x98badcfe;
    let d0 = 0x10325476;
    const shifts = [7, 12, 17, 22, 5, 9, 14, 20, 4, 11, 16, 23, 6, 10, 15, 21];
    const constants = Array.from({ length: 64 }, (_, index) => Math.floor(Math.abs(Math.sin(index + 1)) * 2 ** 32) >>> 0);

    for (let offset = 0; offset < bytes.length; offset += 64) {
        const words = [];
        for (let index = 0; index < 16; index += 1) {
            const start = offset + index * 4;
            words[index] = bytes[start] | (bytes[start + 1] << 8) | (bytes[start + 2] << 16) | (bytes[start + 3] << 24);
        }
        let a = a0;
        let b = b0;
        let c = c0;
        let d = d0;
        for (let index = 0; index < 64; index += 1) {
            let functionValue;
            let wordIndex;
            if (index < 16) {
                functionValue = (b & c) | (~b & d);
                wordIndex = index;
            } else if (index < 32) {
                functionValue = (d & b) | (~d & c);
                wordIndex = (5 * index + 1) % 16;
            } else if (index < 48) {
                functionValue = b ^ c ^ d;
                wordIndex = (3 * index + 5) % 16;
            } else {
                functionValue = c ^ (b | ~d);
                wordIndex = (7 * index) % 16;
            }
            const round = Math.floor(index / 16);
            const shift = shifts[round * 4 + (index % 4)];
            const next = (a + functionValue + constants[index] + words[wordIndex]) | 0;
            const rotated = leftRotate(next, shift);
            const previousD = d;
            d = c;
            c = b;
            b = (b + rotated) | 0;
            a = previousD;
        }
        a0 = (a0 + a) | 0;
        b0 = (b0 + b) | 0;
        c0 = (c0 + c) | 0;
        d0 = (d0 + d) | 0;
    }

    const words = [a0, b0, c0, d0];
    return words.map((word) => {
        let result = "";
        for (let index = 0; index < 4; index += 1) result += ((word >>> (index * 8)) & 0xff).toString(16).padStart(2, "0");
        return result;
    }).join("");
}

function urlIndices(value) {
    if (!value) return { scheme: -1, path: 0, query: 0, fragment: 0 };
    const fragment = value.indexOf("#") === -1 ? value.length : value.indexOf("#");
    const queryIndex = value.indexOf("?");
    const query = queryIndex === -1 || queryIndex > fragment ? fragment : queryIndex;
    const slashIndex = value.indexOf("/");
    const schemeLimit = slashIndex === -1 || slashIndex > query ? query : slashIndex;
    const colonIndex = value.indexOf(":");
    const scheme = colonIndex > schemeLimit ? -1 : colonIndex;
    const hasAuthority = scheme + 2 < query
        && value.length > scheme + 2
        && value.charAt(scheme + 1) === "/"
        && value.charAt(scheme + 2) === "/";
    let path;
    if (hasAuthority) {
        const authoritySlash = value.indexOf("/", scheme + 3);
        path = authoritySlash === -1 || authoritySlash > query ? query : authoritySlash;
    } else {
        path = scheme + 1;
    }
    return { scheme, path, query, fragment };
}

function removeURLDotSegments(value, offset, initialLimit) {
    let result = value;
    let limit = initialLimit;
    if (offset >= limit) return result;
    if (result.charAt(offset) === "/") offset += 1;
    let segmentStart = offset;
    let index = offset;
    while (index <= limit) {
        let nextSegmentStart;
        if (index === limit) nextSegmentStart = index;
        else if (result.charAt(index) === "/") nextSegmentStart = index + 1;
        else {
            index += 1;
            continue;
        }
        if (index === segmentStart + 1 && result.charAt(segmentStart) === ".") {
            result = result.slice(0, segmentStart) + result.slice(nextSegmentStart);
            limit -= nextSegmentStart - segmentStart;
            index = segmentStart;
        } else if (index === segmentStart + 2
            && result.charAt(segmentStart) === "."
            && result.charAt(segmentStart + 1) === ".") {
            const previousSegmentStart = result.lastIndexOf("/", segmentStart - 2) + 1;
            const removeFrom = Math.max(previousSegmentStart, offset);
            result = result.slice(0, removeFrom) + result.slice(nextSegmentStart);
            limit -= nextSegmentStart - removeFrom;
            segmentStart = previousSegmentStart;
            index = previousSegmentStart;
        } else {
            index += 1;
            segmentStart = index;
        }
    }
    return result;
}

export function joinUrl(parent, child) {
    const base = parent == null ? "" : String(parent);
    const relative = child == null ? "" : String(child);
    const reference = urlIndices(relative);
    if (reference.scheme !== -1) {
        return removeURLDotSegments(relative, reference.path, reference.query);
    }
    const baseIndices = urlIndices(base);
    if (reference.fragment === 0) {
        return base.slice(0, baseIndices.fragment) + relative;
    }
    if (reference.query === 0) {
        return base.slice(0, baseIndices.query) + relative;
    }
    if (reference.path !== 0) {
        const baseLimit = baseIndices.scheme + 1;
        const combined = base.slice(0, baseLimit) + relative;
        return removeURLDotSegments(
            combined,
            baseLimit + reference.path,
            baseLimit + reference.query,
        );
    }
    if (relative.charAt(reference.path) === "/") {
        const combined = base.slice(0, baseIndices.path) + relative;
        return removeURLDotSegments(
            combined,
            baseIndices.path,
            baseIndices.path + reference.query,
        );
    }
    if (baseIndices.scheme + 2 < baseIndices.path && baseIndices.path === baseIndices.query) {
        const combined = `${base.slice(0, baseIndices.path)}/${relative}`;
        return removeURLDotSegments(
            combined,
            baseIndices.path,
            baseIndices.path + reference.query + 1,
        );
    }
    const lastSlash = base.lastIndexOf("/", baseIndices.query - 1);
    const baseLimit = lastSlash === -1 ? baseIndices.path : lastSlash + 1;
    const combined = base.slice(0, baseLimit) + relative;
    return removeURLDotSegments(
        combined,
        baseIndices.path,
        baseLimit + reference.query,
    );
}

let hostRequestSequence = 0;
let asyncHostReaderInstalled = false;
const asyncHostRequests = new Map();
const queuedAsyncHostRequests = [];
const maximumAsyncHostRequests = 1;
const queuedInputLines = [];

function hostRequestID() {
    return `quickjs-host-${Date.now()}-${hostRequestSequence++}`;
}

function hostRequestMessage(requestID, capability, operation, payload) {
    return {
        type: "host_request",
        request_id: requestID,
        capability,
        operation,
        ...payload,
    };
}

function sendHostCancel(requestID) {
    std.out.puts(`${JSON.stringify({ type: "host_cancel", request_id: requestID })}\n`);
    std.out.flush();
}

function releaseAsyncHostRequest(requestID) {
    asyncHostRequests.delete(requestID);
    pumpAsyncHostRequests();
    if (asyncHostRequests.size === 0 && queuedAsyncHostRequests.length === 0 && asyncHostReaderInstalled) {
        os.setReadHandler(std.in.fileno(), null);
        asyncHostReaderInstalled = false;
    }
}

function cancelAsyncHostRequests() {
    const pending = Array.from(asyncHostRequests.entries());
    for (const [requestID, request] of pending) {
        sendHostCancel(requestID);
        request.reject(new Error("host request canceled"));
    }
    const queued = queuedAsyncHostRequests.splice(0);
    for (const request of queued) request.reject(new Error("host request canceled"));
}

function dispatchAsyncHostLine(line) {
    let message;
    try {
        message = JSON.parse(line);
    } catch (_) {
        queuedInputLines.push(line);
        return;
    }
    if (message.type === "host_response" && asyncHostRequests.has(message.request_id)) {
        const request = asyncHostRequests.get(message.request_id);
        if (message.ok) request.resolve(message.result || {});
        else request.reject(new Error(message.error?.message || "host request failed"));
        return;
    }
    if (message.operation === "cancel") {
        cancelAsyncHostRequests();
        return;
    }
    queuedInputLines.push(line);
}

function installAsyncHostReader() {
    if (asyncHostReaderInstalled) return;
    asyncHostReaderInstalled = true;
    os.setReadHandler(std.in.fileno(), () => {
        const line = std.in.getline();
        if (line === null) {
            cancelAsyncHostRequests();
            return;
        }
        dispatchAsyncHostLine(line);
    });
}

function pumpAsyncHostRequests() {
    while (asyncHostRequests.size < maximumAsyncHostRequests && queuedAsyncHostRequests.length > 0) {
        const request = queuedAsyncHostRequests.shift();
        asyncHostRequests.set(request.requestID, request);
        try {
            std.out.puts(`${JSON.stringify(hostRequestMessage(
                request.requestID,
                request.capability,
                request.operation,
                request.payload,
            ))}\n`);
            std.out.flush();
        } catch (error) {
            asyncHostRequests.delete(request.requestID);
            request.reject(error);
        }
    }
    if (asyncHostRequests.size > 0) installAsyncHostReader();
}

function hostRequestAsync(capability, operation, payload) {
    const requestID = hostRequestID();
    let resolveRequest;
    let rejectRequest;
    const promise = new Promise((resolve, reject) => {
        resolveRequest = resolve;
        rejectRequest = reject;
    });
    queuedAsyncHostRequests.push({
        requestID,
        capability,
        operation,
        payload,
        resolve: resolveRequest,
        reject: rejectRequest,
    });
    pumpAsyncHostRequests();
    return promise.then((result) => {
        releaseAsyncHostRequest(requestID);
        return result;
    }, (error) => {
        releaseAsyncHostRequest(requestID);
        throw error;
    });
}

function hostRequest(capability, operation, payload) {
    const requestID = hostRequestID();
    const hadAsyncReader = asyncHostReaderInstalled;
    if (hadAsyncReader) {
        os.setReadHandler(std.in.fileno(), null);
        asyncHostReaderInstalled = false;
    }
    std.out.puts(`${JSON.stringify(hostRequestMessage(requestID, capability, operation, payload))}\n`);
    std.out.flush();

    try {
        while (true) {
            const line = std.in.getline();
            if (line === null) throw new Error("host request channel closed");
            const message = JSON.parse(line);
            if (message.type === "host_response" && message.request_id === requestID) {
                if (!message.ok) {
                    throw new Error(message.error?.message || "host request failed");
                }
                return message.result || {};
            }
            if (message.type === "host_response" && asyncHostRequests.has(message.request_id)) {
                dispatchAsyncHostLine(line);
                continue;
            }
            if (message.operation === "cancel") {
                sendHostCancel(requestID);
                cancelAsyncHostRequests();
                throw new Error("host request canceled");
            }
            queuedInputLines.push(line);
        }
    } finally {
        if (hadAsyncReader && asyncHostRequests.size > 0) installAsyncHostReader();
    }
}

export function nextInputLine() {
    return queuedInputLines.length > 0 ? queuedInputLines.shift() : std.in.getline();
}

function httpOptions(options = {}) {
    const copy = { ...options };
    delete copy.complete;
    delete copy.async;
    return copy;
}

function httpContent(result, options = {}) {
    const buffer = Number(options.buffer || 0);
    if (buffer === 2) return result.content_base64 || "";
    if (buffer === 1) {
        // Android JSUtil.toArray(byte[]) exposes signed Java bytes.
        return Array.from(base64DecodeBytes(result.content_base64 || ""), (value) => value > 127 ? value - 256 : value);
    }
    if (buffer === 3) return base64DecodeBytes(result.content_base64 || "");
    if (buffer === 0) return result.content || "";
    return undefined;
}

function httpRequest(url, options = {}) {
    const result = hostRequest("http", "request", {
        url: String(url),
        options: httpOptions(options),
    });
    const response = {
        code: Number(result.code || result.status || 0),
        status: Number(result.status || result.code || 0),
        headers: result.headers || {},
        content_base64: result.content_base64 || "",
        url: result.url || String(url),
    };
    const content = httpContent(result, options);
    if (content !== undefined) response.content = content;
    return response;
}

function httpResponse(result, url, options = {}) {
    const response = {
        code: Number(result.code || result.status || 0),
        status: Number(result.status || result.code || 0),
        headers: result.headers || {},
        content_base64: result.content_base64 || "",
        url: result.url || String(url),
    };
    const content = httpContent(result, options);
    if (content !== undefined) response.content = content;
    return response;
}

async function httpRequestAsync(url, options = {}) {
    const result = await hostRequestAsync("http", "request", {
        url: String(url),
        options: httpOptions(options),
    });
    return httpResponse(result, url, options);
}

function httpError() {
    return { headers: {}, content: "", code: "" };
}

function installHTTPHostAPI() {
    globalThis._http = (url, options = {}) => {
        const complete = options && typeof options.complete === "function" ? options.complete : null;
        if (!complete) {
            try {
                return httpRequest(url, options);
            } catch (_) {
                return httpError();
            }
        }
        httpRequestAsync(url, options).then(complete).catch(() => complete(httpError()));
        return null;
    };
    globalThis.req = (url, options = {}) => globalThis._http(url, { async: false, ...options });
    globalThis.http = (url, options = {}) => {
        const complete = options && typeof options.complete === "function" ? options.complete : null;
        if (options && options.async === false) return globalThis._http(url, options);
        if (complete) return globalThis._http(url, options);
        return httpRequestAsync(url, options)
            .catch(() => httpError());
    };
    globalThis.fetch = async (url, options = {}) => {
        const result = await httpRequestAsync(url, options);
        const text = () => Promise.resolve(typeof result.content === "string" ? result.content : decodeUTF8(result.content));
        return {
            ok: result.status >= 200 && result.status < 300,
            status: result.status,
            url: result.url,
            headers: result.headers,
            text,
            json: async () => JSON.parse(await text()),
            arrayBuffer: async () => base64DecodeBytes(result.content_base64 || ""),
        };
    };
}

function jspQuery(mode, html, rule, extra = {}) {
    const result = hostRequest("jsp", "query", {
        options: {
            mode: String(mode),
            html: String(html || ""),
            rule: String(rule || ""),
            ...extra,
        },
    });
    return result.value;
}

function installJSPHostAPI() {
    const api = {
        pdfa: (html, rule) => jspQuery("pdfa", html, rule),
        pdfh: (html, rule) => jspQuery("pdfh", html, rule),
        pd: (html, rule, urlKey = "") => jspQuery("pd", html, rule, { base_url: String(urlKey || "") }),
        pdfl: (html, texts, urls, urlKey = "") => jspQuery("pdfl", html, urls, {
            texts: String(texts || ""),
            urls: String(urls || ""),
            url_key: String(urlKey || ""),
        }),
    };
    globalThis.jsp = api;
    globalThis.pdfa = api.pdfa;
    globalThis.pdfh = api.pdfh;
    globalThis.pd = api.pd;
    globalThis.pdfl = api.pdfl;
}

function cryptoQuery(operation, options) {
    const result = hostRequest("crypto", operation, { options });
    return result.value;
}

function installCryptoHostAPI() {
    globalThis.aesX = (mode, encrypt, input, inBase64, key, iv, outBase64) => cryptoQuery("aes", {
        mode: String(mode),
        encrypt: Boolean(encrypt),
        input: String(input),
        in_base64: Boolean(inBase64),
        key: String(key),
        iv: iv === null || iv === undefined ? null : String(iv),
        out_base64: Boolean(outBase64),
    });
    globalThis.rsaX = (mode, pub, encrypt, input, inBase64, key, outBase64) => cryptoQuery("rsa", {
        mode: String(mode),
        pub: Boolean(pub),
        encrypt: Boolean(encrypt),
        input: String(input),
        in_base64: Boolean(inBase64),
        key: String(key),
        out_base64: Boolean(outBase64),
    });
}

function persistenceQuery(operation, options) {
    const result = hostRequest("persistence", operation, { options });
    return result.value;
}

function installPersistenceHostAPI() {
    const api = {
        get: (rule, key) => persistenceQuery("get", {
            rule: String(rule || ""),
            key: String(key),
        }),
        set: (rule, key, value) => {
            persistenceQuery("set", {
                rule: String(rule || ""),
                key: String(key),
                value: String(value),
            });
        },
        delete: (rule, key) => {
            persistenceQuery("delete", {
                rule: String(rule || ""),
                key: String(key),
            });
        },
    };
    globalThis.local = api;
}

const installedTimers = new Map();
let nextTimerID = 1;

function normalizedTimerDelay(delay) {
    const value = Number(delay);
    return Number.isFinite(value) ? Math.min(2_147_483_647, Math.max(0, value)) : 0;
}

function scheduleTimer(callback, delay, repeat, callbackArguments) {
    if (typeof callback !== "function") throw new TypeError("Timer callback must be a function");
    const timerID = nextTimerID++;
    if (nextTimerID > 2_147_483_647) nextTimerID = 1;
    const timer = {
        nativeID: null,
        delay: normalizedTimerDelay(delay),
        repeat,
    };
    // Register before arming the native timer. QuickJS may run a 0ms timer
    // immediately, and the callback must observe its stable public ID.
    installedTimers.set(timerID, timer);
    const fire = () => {
        if (installedTimers.get(timerID) !== timer) return;
        if (!repeat) installedTimers.delete(timerID);
        try {
            callback(...callbackArguments);
        } finally {
            if (repeat && installedTimers.get(timerID) === timer) {
                timer.nativeID = os.setTimeout(fire, timer.delay);
            }
        }
    };
    try {
        timer.nativeID = os.setTimeout(fire, timer.delay);
    } catch (error) {
        installedTimers.delete(timerID);
        throw error;
    }
    return timerID;
}

function clearTimer(timerID) {
    const timer = installedTimers.get(Number(timerID));
    if (!timer) return;
    installedTimers.delete(Number(timerID));
    os.clearTimeout(timer.nativeID);
}

function installTimerHostAPI() {
    globalThis.setTimeout = (callback, delay = 0, ...args) => scheduleTimer(callback, delay, false, args);
    globalThis.clearTimeout = clearTimer;
    globalThis.setInterval = (callback, delay = 0, ...args) => scheduleTimer(callback, delay, true, args);
    globalThis.clearInterval = clearTimer;
}

export function clearInstalledTimers() {
    for (const timer of installedTimers.values()) os.clearTimeout(timer.nativeID);
    installedTimers.clear();
}

function installTextHostAPI() {
    const textQuery = (operation, value) => {
        const result = hostRequest("text", operation, { options: { value: String(value) } });
        return typeof result.value === "string" ? result.value : String(value);
    };
    globalThis.s2t = (value) => textQuery("s2t", value);
    globalThis.t2s = (value) => textQuery("t2s", value);
}

function localProxyQuery(operation, options = {}) {
    return hostRequest("local_proxy", operation, { options });
}

function installLocalProxyHostAPI() {
    globalThis.getPort = () => Number(localProxyQuery("get_port").port || 0);
    globalThis.getProxy = (local = true) => String(localProxyQuery("get_proxy", { local: Boolean(local) }).url || "");
    globalThis.js2Proxy = (dynamic, siteType, siteKey, url, headers = {}) => String(localProxyQuery("js2_proxy", {
        dynamic: Boolean(dynamic),
        site_type: Number(siteType),
        site_key: String(siteKey),
        url: String(url),
        headers,
    }).url || "");
}

export function installCoreHostAPI(enabledCapabilities = []) {
    const enabled = new Set(enabledCapabilities);
    const installed = ["console"];
    if (enabled.has("base64")) {
        globalThis.base64Encode = base64Encode;
        globalThis.base64Decode = base64Decode;
        installed.push("base64");
    }
    if (enabled.has("md5")) {
        globalThis.md5X = md5X;
        globalThis.md5 = md5X;
        installed.push("md5");
    }
    if (enabled.has("url")) {
        globalThis.joinUrl = joinUrl;
        installed.push("url");
    }
    if (enabled.has("http")) {
        installHTTPHostAPI();
        installed.push("http");
    }
    if (enabled.has("jsp")) {
        installJSPHostAPI();
        installed.push("jsp");
    }
    if (enabled.has("crypto")) {
        installCryptoHostAPI();
        installed.push("crypto");
    }
    if (enabled.has("persistence")) {
        installPersistenceHostAPI();
        installed.push("persistence");
    }
    if (enabled.has("timer")) {
        installTimerHostAPI();
        installed.push("timer");
    }
    if (enabled.has("text")) {
        installTextHostAPI();
        installed.push("text");
    }
    if (enabled.has("local_proxy")) {
        installLocalProxyHostAPI();
        installed.push("local_proxy");
    }
    if (typeof console === "object" && typeof console.log === "function") {
        console.log = (...values) => std.err.puts(`${values.map(String).join(" ")}\n`);
    }
    return installed;
}
