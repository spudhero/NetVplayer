#!/usr/bin/env node
import { createInterface } from "node:readline";
import { pathToFileURL } from "node:url";
import path from "node:path";
import fs from "node:fs";
import { registerHooks } from "node:module";

const protocol = 1;
const providerPath = path.resolve(process.argv[process.argv.indexOf("--provider") + 1] || "");
const packageRoot = path.resolve(process.env.NETVPLAYER_PROVIDER_ROOT || path.dirname(providerPath));
const providerID = process.env.NETVPLAYER_PROVIDER_ID || path.basename(providerPath, path.extname(providerPath));
const classIndex = process.argv.indexOf("--class");
const className = classIndex >= 0 ? process.argv[classIndex + 1] : null;
const maximumProxyBytes = Number(process.env.NETVPLAYER_MAX_PROXY_BYTES || 32 * 1024 * 1024);
function safeMessage(value) {
  return String(value).replace(/https?:\/\/[^\s"'<>]+/g, "<redacted-url>").replace(/(cookie|authorization|proxy-authorization|x-api-key)\s*:\s*[^\r\n]+/ig, "$1: <redacted>");
}

function isInside(candidate, root) {
  const relative = path.relative(fs.realpathSync(root), fs.realpathSync(candidate));
  return relative !== ".." && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative);
}

if (!providerPath || !isInside(providerPath, packageRoot) || ![".js", ".mjs"].includes(path.extname(providerPath))) {
  process.stderr.write("Provider entrypoint must be a package-local JavaScript module\n");
  process.exit(2);
}

registerHooks({
  resolve(specifier, context, nextResolve) {
    if (/^(https?:|data:)/i.test(specifier)) throw new Error(`remote JavaScript import is forbidden: ${specifier}`);
    const result = nextResolve(specifier, context);
    if (result.url.startsWith("node:")) return result;
    if (!result.url.startsWith("file:")) throw new Error(`unsupported JavaScript import: ${specifier}`);
    const resolved = new URL(result.url);
    if (!isInside(resolved, packageRoot)) throw new Error(`JavaScript import escaped the signed package: ${specifier}`);
    return result;
  },
});

const originalLog = console.log;
console.log = (...values) => console.error(...values);
let moduleValue;
try {
  moduleValue = await import(pathToFileURL(providerPath).href);
} catch (error) {
  process.stderr.write(`${error.stack || error}\n`);
  process.exit(2);
}
console.log = originalLog;

let target = className ? moduleValue[className] : (moduleValue.Spider || moduleValue.default || moduleValue.spider || moduleValue);
if (typeof target === "function") target = new target();

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

function resultValue(value) {
  if (typeof value === "string") {
    const trimmed = value.trim();
    if ((trimmed.startsWith("{") && trimmed.endsWith("}")) || (trimmed.startsWith("[") && trimmed.endsWith("]"))) {
      try { return JSON.parse(trimmed); } catch (_) { return value; }
    }
  }
  if (Buffer.isBuffer(value) || value instanceof Uint8Array) return { body_base64: Buffer.from(value).toString("base64") };
  return value ?? null;
}

async function proxyBody(body) {
  if (body == null || typeof body === "string" || Buffer.isBuffer(body) || body instanceof Uint8Array) return [body, Buffer.isBuffer(body) || body instanceof Uint8Array];
  if (body[Symbol.asyncIterator] || body[Symbol.iterator]) {
    const chunks = [];
    let size = 0;
    for await (const chunk of body) {
      const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      size += bytes.length;
      if (size > maximumProxyBytes) throw new Error("proxy stream exceeds the configured byte limit");
      chunks.push(bytes);
    }
    return [Buffer.concat(chunks), true];
  }
  return [body, false];
}

async function proxyValue(value) {
  if (Array.isArray(value)) {
    const [status = 200, contentType = null, rawBody = null, headers = {}, forceBase64 = false] = value;
    const [body, streamBody] = await proxyBody(rawBody);
    const bytes = Buffer.isBuffer(body) || body instanceof Uint8Array || streamBody;
    return {
      status_code: Number(status), content_type: contentType, headers,
      ...(body == null ? {} : ((forceBase64 || bytes)
        ? { body_base64: Buffer.from(body).toString("base64") }
        : { body: String(body) })),
    };
  }
  if (value && typeof value === "object") {
    const payload = { ...value };
    payload.status_code = Number(payload.status_code ?? payload.code ?? 200);
    delete payload.code;
    const [body, streamBody] = await proxyBody(payload.body);
    payload.body = body;
    if (Buffer.isBuffer(payload.body) || payload.body instanceof Uint8Array || streamBody) {
      payload.body_base64 = Buffer.from(payload.body).toString("base64");
      delete payload.body;
    }
    payload.headers ||= {};
    return payload;
  }
  throw new Error("proxy/localProxy must return an object or CatVod response array");
}

async function invoke(request) {
  const requestID = String(request.request_id ?? "");
  try {
    if (request.protocol !== protocol) throw new Error("unsupported protocol");
    if (request.provider_id && request.provider_id !== providerID) throw new Error("provider_id does not match the launched package");
    if (request.operation === "handshake") return ok(requestID, { protocol, provider_id: providerID, runtime: "js", operations: Object.keys(methods) });
    if (request.operation === "health") return ok(requestID, { status: "ok" });
    if (request.operation === "cancel") return ok(requestID, { cancelled: request.arguments?.target_request_id ?? "" });
    if (request.operation === "shutdown") {
      if (typeof target.destroy === "function") await target.destroy();
      return ok(requestID, { shutdown: true });
    }
    const descriptor = methods[request.operation];
    if (!descriptor) throw new Error(`unsupported operation: ${request.operation}`);
    let [name, makeArguments] = descriptor;
    if (request.operation === "proxy" && typeof target[name] !== "function") name = "proxy";
    if (typeof target[name] !== "function") throw new Error(`provider does not implement ${name}`);
    const savedLog = console.log;
    console.log = (...values) => console.error(...values);
    let value;
    let methodArguments = makeArguments(request.arguments || {});
    if (request.operation === "action" && target[name].length === 1) methodArguments = methodArguments.slice(0, 1);
    try { value = await target[name](...methodArguments); }
    finally { console.log = savedLog; }
    if (request.operation === "proxy") return { request_id: requestID, ok: true, result: null, proxy: await proxyValue(value), error: null };
    return ok(requestID, resultValue(value));
  } catch (error) {
    process.stderr.write(`${error.constructor?.name || "Error"}: ${safeMessage(error.message || error)}\n`);
    return { request_id: requestID, ok: false, result: null, error: { code: "provider_error", message: safeMessage(error.message || error), retryable: false, diagnostic: error.constructor?.name || "Error" } };
  }
}

function ok(requestID, result) {
  return { request_id: requestID, ok: true, result, error: null };
}

const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
for await (const line of input) {
  let request;
  let response;
  try { request = JSON.parse(line); response = await invoke(request); }
  catch (error) { response = { request_id: "", ok: false, result: null, error: { code: "invalid_request", message: safeMessage(error.message || error), retryable: false, diagnostic: error.constructor?.name || "Error" } }; }
  process.stdout.write(`${JSON.stringify(response)}\n`);
  if (request?.operation === "shutdown") break;
}
input.close();
process.stdin.destroy();
