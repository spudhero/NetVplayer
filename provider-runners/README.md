# NetVplayer Provider Runners

The Provider Runners connect package-local Java, Node.js, QuickJS, and Python code to NetVplayer Provider protocol v1. Start with the bilingual [Provider SDK guide](../provider-sdk/README.md) for the complete development and packaging workflow.

## Runtime I/O contract

Each Runner reads one UTF-8 JSON request per line from stdin and writes one JSON response per line to stdout. Provider logs are redirected to stderr so they cannot corrupt the wire stream.

The shell supplies these environment values:

| Variable | Purpose |
| --- | --- |
| `NETVPLAYER_PROVIDER_ROOT` | Canonical root of the verified Provider package |
| `NETVPLAYER_PROVIDER_ID` | Provider ID that every request and handshake must match |
| `NETVPLAYER_MAX_PROXY_BYTES` | Maximum buffered proxy payload; the default is 32 MiB |
| `NETVPLAYER_PROVIDER_HOST_CAPABILITIES` | Comma-separated QuickJS host capabilities granted by the signed manifest |

Entrypoints, imports, dependencies, and runtime executables must resolve inside `NETVPLAYER_PROVIDER_ROOT`. Runners reject package escapes and do not download code or install dependencies at runtime.

## Runtime contracts

### Python

`python/provider_runner.py` loads a package-local `.py` entrypoint and supports the CatVod lifecycle, proxy responses, package-local `dependencies/`, cancellation tracking, and an optional `site` argument for `init`.

Development can use Python 3. A distributable package must declare a signed, relocatable, package-local CPython executable and must run in isolated mode without the user's site packages.

### Node.js

`js/provider_runner.mjs` loads package-local ES modules and supports synchronous or asynchronous Provider methods. Node built-ins are allowed; remote module imports, CommonJS entrypoints, non-file imports, and paths outside the signed package are rejected.

The supported runtime is Node.js 22.20.0 with `module.registerHooks`. A distributable package must declare its package-local Node executable instead of relying on the user's `PATH`.

### QuickJS

`quickjs/provider_runner.mjs` runs with the locked QuickJS 2026-06-04 runtime. It validates the package-local module graph, keeps stdout protocol-only, bounds proxy payloads, and exposes only host capabilities declared by the signed manifest.

Available host capabilities are `console`, `base64`, `md5`, `url`, `http`, `jsp`, `crypto`, `persistence`, `text`, `module`, `timer`, and `local_proxy`. Host requests use request IDs and a bounded single-in-flight queue. Cancellation rejects queued work and forwards cancellation for an in-flight host request.

### Java

`java/` contains the Java 21 Runner, the `NetVplayerProvider` interface, and a reflection adapter for conventional CatVod method names. The stable interface is:

```java
public interface NetVplayerProvider {
    JsonElement invoke(String operation, JsonObject arguments) throws Exception;
}
```

The Runner loads only the manifest-selected package-local JAR and class. A distributable package must carry a Java 21 `jlink` image and its required signed dependencies, including Gson when used by the Runner or Provider.

## Standard CatVod mapping

| Operation | Provider method |
| --- | --- |
| `init` | `init(ext[, site])` |
| `home` | `homeContent(filter)` |
| `home_video` | `homeVideoContent()` |
| `category` | `categoryContent(category_id, page, filter, extend)` |
| `search` | `searchContent(keyword, quick, page)` |
| `detail` | `detailContent(ids)` |
| `player` | `playerContent(flag, id, vip_flags)` |
| `live` | `liveContent(url)` |
| `proxy` | `localProxy(parameters)` or `proxy(parameters)` |
| `action` | `action(action[, value])` |
| `manual_video_check` | `manualVideoCheck()` |
| `is_video_format` | `isVideoFormat(url)` |
| `destroy` | `destroy()` |

`handshake`, `health`, `cancel`, and `shutdown` are Runner-owned lifecycle operations. Protocol v1 declares `epg`, but the standard CatVod Runners do not map an EPG method; a package must not advertise EPG through these Runners.

## Signed package requirements

Every Runner, runtime, Provider, dependency, and license file must be declared in the signed manifest with a package-relative path, SHA-256, and executable flag. The package validator rejects undeclared payloads, missing runtime executables, path traversal, symlinks, digest mismatches, and metadata drift.

Manifest examples are provided for each runtime:

- `java/fixtures/manifest.template.json`
- `js/fixtures/manifest.template.json`
- `python/fixtures/manifest.template.json`

These templates are inputs to package assembly. `script/build_provider_package.py` computes the final asset hashes and adds the required `LICENSES/PROVIDER.txt`.

## Verification

Run the public contract checks from the repository root:

```bash
python3 script/test_provider_runners.py -v
python3 script/test_provider_package.py -v
python3 script/test_quickjs_provider_runner.py
python3 script/test_quickjs_provider_golden.py
```

Validate an assembled archive:

```bash
python3 script/validate_provider_package.py \
  /absolute/path/to/provider.zip
```

Validate the package-local runtime before distribution:

```bash
python3 script/validate_java_runtime.py \
  /absolute/path/to/jre --version 21

python3 script/validate_node_runtime.py \
  /absolute/path/to/node-runtime --version 22

python3 script/validate_cpython_runtime.py \
  /absolute/path/to/cpython-runtime --version 3.12
```

Use each command's `--help` output as the source of truth for required paths and optional release parameters. Passing these local checks does not make the official application trust a package; official distribution also requires approved signing keys, App Sandbox validation, license and service-term review, and inclusion in the signed distribution index.
