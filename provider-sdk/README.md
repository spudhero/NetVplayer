# NetVplayer Provider SDK

[中文](#中文) | [English](#english) | [Wire Schema](schema/provider-wire-v1.schema.json) | [Manifest Schema](schema/provider-manifest-v1.schema.json) | [Runner reference](../provider-runners/README.md)

> [!IMPORTANT]
> This is an extension SDK for building Providers that work with user-supplied configurations. It is not a player-control SDK, a video-source catalog, or a way to bypass access controls. The SDK, examples, and official public application contain no video sources or credentials.

## 中文

### SDK 的用途

Provider SDK 定义 NetVplayer 主应用与独立扩展进程之间的稳定边界。第三方开发者可以使用受支持的 Runner 实现内容目录、搜索、详情、播放候选、直播或本地代理适配，然后在本机完成协议和包结构验证。

SDK 由四部分组成：

| 组成 | 路径 | 用途 |
| --- | --- | --- |
| Swift 合同 | `NetVplayer/Sources/ProviderSDK` | 主应用侧的 wire、manifest、catalog、source descriptor、distribution 和诊断类型 |
| JSON Schema | `provider-sdk/schema` | 与语言无关的 protocol v1、manifest v1、distribution index v1/v2 等格式 |
| Runner | `provider-runners` | Java、Node.js、QuickJS 和 Python 的 JSONL 进程适配器 |
| 工具 | `script` | Runner 测试、签名打包、结构验证、运行时验证和发行检查 |

普通 Provider 开发者不需要链接 Swift 模块。以对应语言实现 Provider 类，通过 Runner 和 JSON Schema 对接即可。`ProviderSDK` Swift library 主要供 NetVplayer 壳层和同仓库 Swift 工具使用。

### 五分钟运行第一个 Provider

#### 前置条件

- macOS 或其它可运行 Python 3 的开发环境；正式 App 包仍以 macOS 为目标。
- NetVplayer 仓库检出。
- 从仓库根目录执行以下命令。

#### 1. 运行无网络 fixture

下面的 fixture 只返回静态测试数据，不访问任何视频服务：

```bash
NETVPLAYER_REPO="$(pwd)"

env \
  NETVPLAYER_PROVIDER_ROOT="$NETVPLAYER_REPO/provider-runners/python" \
  NETVPLAYER_PROVIDER_ID="example.python" \
  python3 provider-runners/python/provider_runner.py \
    --provider "$NETVPLAYER_REPO/provider-runners/python/fixtures/mock_provider.py" \
    --class Spider <<'EOF'
{"protocol":1,"request_id":"1","provider_id":"example.python","operation":"handshake","arguments":{}}
{"protocol":1,"request_id":"2","provider_id":"example.python","operation":"init","arguments":{"ext":"demo"}}
{"protocol":1,"request_id":"3","provider_id":"example.python","operation":"home","arguments":{"filter":true}}
{"protocol":1,"request_id":"4","provider_id":"example.python","operation":"shutdown","arguments":{}}
EOF
```

成功时 stdout 依次返回四个 JSON 对象：

```json
{"request_id":"1","ok":true,"result":{"protocol":1,"provider_id":"example.python","runtime":"python","operations":["init","home","home_video","category","detail","search","player","live","manual_video_check","is_video_format","proxy","action","destroy"]},"error":null}
{"request_id":"2","ok":true,"result":null,"error":null}
{"request_id":"3","ok":true,"result":{"class":[{"type_id":"movie","type_name":"Movies"}],"list":[]},"error":null}
{"request_id":"4","ok":true,"result":{"shutdown":true},"error":null}
```

Runner 的 stdout 只承载 JSONL 协议。Provider 的日志必须写入 stderr；现有 Runner 会把 Python `print`、Java `System.out` 和 JavaScript `console.log` 重定向到 stderr。

#### 2. 实现最小 Python Provider

以下类展示最小生命周期。它不包含网络地址，并保持首页为空：

```python
class Spider:
    def __init__(self):
        self.ext = None
        self.site = None

    def init(self, ext, site=None):
        self.ext = ext
        self.site = site

    def homeContent(self, filter_enabled):
        return {"class": [], "list": []}

    def destroy(self):
        self.ext = None
        self.site = None
```

将它保存到包根目录内的 `provider.py`，然后把快速入门命令中的 `--provider` 改为该文件。只有 manifest 声明的能力才需要实现；缺少被调用的方法时 Runner 会返回 `provider_error`。

生产 Provider 必须从 `init` 的 `ext` 或可选 `site` 参数读取用户配置。不要在 Provider、manifest、测试输出或文档中硬编码视频源、完整媒体 URL、Cookie、Authorization 或 API key。

### Protocol v1

Wire 使用 stdin/stdout 上的 newline-delimited JSON。每行只能有一个 UTF-8 JSON 对象；未知字段会被忽略，以便协议向前兼容。

#### 请求与响应

| 字段 | 必需 | 说明 |
| --- | :---: | --- |
| `protocol` | 是 | 当前固定为 `1` |
| `request_id` | 是 | 非空请求标识；响应必须原样返回 |
| `provider_id` | 是 | 必须与已启动包的 Provider ID 一致 |
| `operation` | 是 | 生命周期、CatVod 或代理操作 |
| `arguments` | 是 | 操作参数对象，可以为空 |
| `site` | 否 | 用户选择的站点上下文；Runner 可在 `init` 时传入 |
| `credential_ref` | 否 | 壳层管理的凭据引用，不是明文凭据 |

成功响应设置 `ok: true`，并返回 `result` 或 `proxy`。失败响应设置 `ok: false`，并返回包含 `code`、`message`、`retryable` 和可选 `diagnostic` 的 `error`。`proxy` 支持 `status_code`、`content_type`、`url`、`body`、`body_base64` 和字符串响应头；状态码必须在 100 到 599 之间。

#### 生命周期和方法映射

| Wire operation | 由谁处理 | 标准 Runner 方法 / 参数 |
| --- | --- | --- |
| `handshake` | Runner | 返回 protocol、provider ID、runtime 和操作列表 |
| `health` | Runner | 返回 `status: ok` |
| `cancel` | Runner | `arguments.target_request_id`；Python Runner 记录取消，其它 Runner 确认请求 |
| `shutdown` | Runner | 调用 `destroy` 后退出进程 |
| `init` | Provider | `init(ext[, site])` |
| `home` | Provider | `homeContent(filter)` |
| `home_video` | Provider | `homeVideoContent()` |
| `category` | Provider | `categoryContent(category_id, page, filter, extend)` |
| `search` | Provider | `searchContent(keyword, quick, page)` |
| `detail` | Provider | `detailContent(ids)` |
| `player` | Provider | `playerContent(flag, id, vip_flags)` |
| `live` | Provider | `liveContent(url)` |
| `proxy` | Provider | `localProxy(parameters)`，缺失时尝试 `proxy(parameters)` |
| `action` | Provider | `action(action[, value])` |
| `manual_video_check` | Provider | `manualVideoCheck()` |
| `is_video_format` | Provider | `isVideoFormat(url)` |
| `destroy` | Provider | `destroy()` |

`epg` 已由 protocol v1 和 manifest capability 声明，但当前标准 CatVod Runner 没有 EPG 方法映射。只有提供并签名自定义 protocol v1 Runner、通过壳层兼容审查后才能实现该操作；不要仅因 Schema 中存在 `epg` 就在标准 Runner 包中声明可用。

完整格式以 [provider-wire-v1.schema.json](schema/provider-wire-v1.schema.json) 和 Swift [`ProviderProtocol.swift`](../NetVplayer/Sources/ProviderSDK/ProviderProtocol.swift) 为准。

### 选择运行时

| Runtime | 开发入口 | 当前要求 | 适用场景 |
| --- | --- | --- | --- |
| Python | `provider-runners/python/provider_runner.py` | Python 3；正式包使用签名的包内 CPython | 快速开发、标准库抓取与 CatVod 适配 |
| Java | `provider-runners/java` | Java 21、Gson；正式包使用包内 `jlink` image | 已有 Java/CatVod 类或需要 JCA/强类型实现 |
| Node.js | `provider-runners/js/provider_runner.mjs` | Node.js 22.20.0；ES modules | 需要 Node 标准库和异步 JavaScript 的 Provider |
| QuickJS | `provider-runners/quickjs/provider_runner.mjs` | 锁定 QuickJS 2026-06-04 | 需要受控 HTTP/JSP/crypto/persistence 等 host capability 的脚本 |
| Android Dex | 无直接 Runner | 仅用于兼容性评估，状态保持 `needs-port` | 不能在 macOS 直接运行 |

所有正式包都必须声明包内 `runtime_executable`。依赖必须作为签名 asset 一起提供；Runner 不会调用 `pip`、下载远程 ES module 或从用户 PATH 动态补齐生产依赖。

### Manifest v1

Manifest 经过规范化 JSON 编码和 Ed25519 签名。主要字段如下：

| 字段 | 说明 |
| --- | --- |
| `provider_id`, `version`, `protocol` | 稳定 ID、版本和 protocol `1` |
| `shell_min_version`, `shell_max_version` | 兼容的 NetVplayer 版本范围 |
| `macos_min_version`, `architectures` | 最低 macOS 和 `arm64` / `x86_64` / `universal2` 边界 |
| `runtime`, `runtime_executable` | 运行时类型和签名包内的可执行文件 |
| `entrypoint`, `runner`, `provider_class` | Provider、Runner 和可选入口类 |
| `capabilities` | `vod/home/category/search/detail/player/live/epg/proxy/action` 子集 |
| `host_capabilities` | `console/base64/md5/url/http/jsp/crypto/persistence/text/module/timer/local_proxy` 子集 |
| `assets` | 每个包内文件的相对路径、SHA-256 和 executable 标记 |
| `source_bindings` | 用户配置中的精确 key/API 身份；不支持通配模式 |
| `source_policy` | `user-configured-only` 或 `user-configured-catalog` |
| `source_revision`, `license`, `status`, `revoked` | 来源修订、许可证、兼容状态和吊销状态 |
| `sandbox` | App Sandbox v2 launcher、bundle ID 和发行签名 profile |

一个 Python 开发 manifest 可以从以下形状开始：

```json
{
  "provider_id": "example.python",
  "version": "1.0.0",
  "protocol": 1,
  "shell_min_version": "1.0.0",
  "shell_max_version": null,
  "macos_min_version": "14.0",
  "architectures": ["arm64"],
  "runtime": "python",
  "entrypoint": "provider.py",
  "runner": "provider_runner.py",
  "runtime_executable": "runtimes/cpython/bin/python3",
  "provider_class": "Spider",
  "capabilities": ["home", "category", "search", "detail", "player"],
  "host_capabilities": [],
  "assets": [
    {"path": "provider.py", "sha256": "", "executable": false},
    {"path": "provider_runner.py", "sha256": "", "executable": false},
    {"path": "runtimes/cpython/bin/python3", "sha256": "", "executable": true}
  ],
  "source_bindings": [
    {"original_keys": ["example-user-configured"], "original_apis": []}
  ],
  "source_policy": "user-configured-only",
  "source_revision": "1.0.0",
  "license": "MIT",
  "status": "compatible",
  "revoked": false
}
```

`build_provider_package.py` 会计算并写入 asset 哈希，并通过 `--license-file` 添加唯一的 `LICENSES/PROVIDER.txt`。不要在输入 manifest 中自行添加该受管文件。

普通 `user-configured-only` Provider 的适配器和 binding 不得嵌入网络 authority。当前公开壳的自动安装和手动重试只接受 `user-configured-only`。`user-configured-catalog` 只适用于经过审查、仍由用户配置触发的目录适配，并且必须提供精确 `source_bindings`；它需要单独的壳层与发行审查，不能借当前自动安装路径激活。字段约束以 [provider-manifest-v1.schema.json](schema/provider-manifest-v1.schema.json) 为准，无源策略由官方发行审计执行。

### 从开发到发行

#### 1. 运行合同测试

```bash
python3 script/test_provider_runners.py -v
python3 script/test_provider_package.py -v
```

Java fixture 需要预先构建的测试 JAR 和 Gson；缺少时 Runner 测试会具名跳过 Java 用例。QuickJS 使用独立测试：

```bash
python3 script/test_quickjs_provider_runner.py
python3 script/test_quickjs_provider_golden.py
```

#### 2. 创建仅供本地开发的签名包

先准备完整的包内 runtime、Runner、Provider、依赖和非空许可证文件，再创建一次性开发密钥：

```bash
openssl genpkey -algorithm ED25519 \
  -out /private/tmp/netvplayer-provider-dev-key.pem

python3 script/build_provider_package.py \
  --source /absolute/path/to/package-root \
  --manifest /absolute/path/to/manifest.json \
  --license-file /absolute/path/to/PROVIDER-LICENSE.txt \
  --private-key /private/tmp/netvplayer-provider-dev-key.pem \
  --output /private/tmp/example-python-provider.zip

python3 script/validate_provider_package.py \
  /private/tmp/example-python-provider.zip
```

这一步证明 manifest、签名、哈希和 ZIP 结构可以生成并通过静态验证，不代表官方 App 会信任该包，也不满足 App Sandbox 或正式发行验收。

#### 3. 通过正式发行门禁

进入官方分发索引还需要：

1. 使用项目批准的长期 manifest/index 密钥和固定 HTTPS 归档地址。
2. 为每个 Provider 构建并签名 App Sandbox v2 launcher。
3. 验证包内 Java/Node/QuickJS/CPython runtime 的版本、架构和 Mach-O 依赖。
4. 通过 archive、manifest、catalog、source-policy、sandbox、运行时、协议生命周期和吊销/回滚测试。
5. 单独审查 Provider 源码许可证、依赖许可证、目标服务条款和用户授权路径。
6. 由 NetVplayer 维护者审查并加入签名 distribution index。

开发密钥生成的包不会被官方 App 信任。不要要求用户替换应用内公钥、关闭验签或绕过固定索引来安装第三方包。

### 常见问题

**Runner 返回 `invalid_request` 或 `unsupported protocol`**

检查每一行是否是完整 JSON 对象，并确认 `protocol` 为数字 `1`、`request_id` 非空、`provider_id` 与环境变量一致。

**日志破坏了 JSONL**

不要直接向 stdout 写日志。使用 stderr，并保持 stdout 每行只有一个响应对象。

**Provider 或依赖无法加载**

`entrypoint`、Runner 和所有依赖必须解析到 `NETVPLAYER_PROVIDER_ROOT` 内，并在 manifest `assets` 中逐项声明。符号链接、`..` 路径、远程 import 和未声明文件会被拒绝。

**本地包验证成功，但官方 App 没有加载**

本地结构验证不建立信任。官方 App 只接受固定签名索引和项目批准的 manifest 公钥；请按正式发行门禁提交审核。

**如何处理账号和凭据**

不要在代码、manifest、日志或 issue 中保存明文凭据。使用用户主动配置和壳层提供的凭据引用；错误信息必须脱敏。

## English

### What the SDK is for

The Provider SDK defines the stable boundary between NetVplayer and a separate extension process. Third-party developers can implement catalog, search, detail, playback-candidate, live, or local-proxy adapters with a supported Runner, then validate the protocol and package structure locally.

The SDK has four parts:

| Part | Path | Purpose |
| --- | --- | --- |
| Swift contracts | `NetVplayer/Sources/ProviderSDK` | Shell-side wire, manifest, catalog, source descriptor, distribution, and diagnostic types |
| JSON Schemas | `provider-sdk/schema` | Language-neutral protocol v1, manifest v1, distribution index v1/v2, and related formats |
| Runners | `provider-runners` | JSONL process adapters for Java, Node.js, QuickJS, and Python |
| Tools | `script` | Runner tests, signed packaging, structural validation, runtime validation, and release checks |

Most Provider authors do not link the Swift module. Implement the Provider class in a supported language and use the matching Runner and JSON Schemas. The Swift `ProviderSDK` library primarily serves the NetVplayer shell and Swift tools in this repository.

### Run a Provider in five minutes

Prerequisites:

- macOS or another development environment with Python 3; distributable application packages still target macOS.
- A NetVplayer repository checkout.
- A shell opened at the repository root.

Run the network-free Python fixture. It returns static test data and does not contact a content service:

```bash
NETVPLAYER_REPO="$(pwd)"

env \
  NETVPLAYER_PROVIDER_ROOT="$NETVPLAYER_REPO/provider-runners/python" \
  NETVPLAYER_PROVIDER_ID="example.python" \
  python3 provider-runners/python/provider_runner.py \
    --provider "$NETVPLAYER_REPO/provider-runners/python/fixtures/mock_provider.py" \
    --class Spider <<'EOF'
{"protocol":1,"request_id":"1","provider_id":"example.python","operation":"handshake","arguments":{}}
{"protocol":1,"request_id":"2","provider_id":"example.python","operation":"init","arguments":{"ext":"demo"}}
{"protocol":1,"request_id":"3","provider_id":"example.python","operation":"home","arguments":{"filter":true}}
{"protocol":1,"request_id":"4","provider_id":"example.python","operation":"shutdown","arguments":{}}
EOF
```

Successful stdout contains four JSON objects in order:

```json
{"request_id":"1","ok":true,"result":{"protocol":1,"provider_id":"example.python","runtime":"python","operations":["init","home","home_video","category","detail","search","player","live","manual_video_check","is_video_format","proxy","action","destroy"]},"error":null}
{"request_id":"2","ok":true,"result":null,"error":null}
{"request_id":"3","ok":true,"result":{"class":[{"type_id":"movie","type_name":"Movies"}],"list":[]},"error":null}
{"request_id":"4","ok":true,"result":{"shutdown":true},"error":null}
```

Runner stdout is reserved for JSONL. Provider logs belong on stderr. The supplied Runners redirect Python `print`, Java `System.out`, and JavaScript `console.log` accordingly.

A minimal Provider can start with this lifecycle:

```python
class Spider:
    def __init__(self):
        self.ext = None
        self.site = None

    def init(self, ext, site=None):
        self.ext = ext
        self.site = site

    def homeContent(self, filter_enabled):
        return {"class": [], "list": []}

    def destroy(self):
        self.ext = None
        self.site = None
```

Save it as `provider.py` inside the package root and point `--provider` at that file. Implement only the capabilities declared by the manifest. A call to a missing method returns `provider_error`.

Production Providers must obtain their configuration from `ext` or the optional `site` passed to `init`. Do not hard-code a video source, full media URL, Cookie, Authorization value, or API key in Provider code, manifests, test output, or documentation.

### Protocol v1

The wire is newline-delimited JSON over stdin/stdout. Each line contains exactly one UTF-8 JSON object. Unknown fields are ignored for forward compatibility.

Requests require `protocol`, `request_id`, `provider_id`, `operation`, and `arguments`. They may also carry a user-selected `site` and an opaque `credential_ref`. Responses echo `request_id`; success returns `ok: true` with `result` or `proxy`, while failure returns `ok: false` with a structured `error`.

| Field | Required | Meaning |
| --- | :---: | --- |
| `protocol` | Yes | Currently fixed at numeric `1` |
| `request_id` | Yes | Non-empty request identifier echoed by the response |
| `provider_id` | Yes | Must match the launched Provider package |
| `operation` | Yes | Lifecycle, CatVod, or proxy operation |
| `arguments` | Yes | Operation argument object; it may be empty |
| `site` | No | User-selected site context, optionally passed to `init` |
| `credential_ref` | No | Opaque shell-managed reference, never plaintext credentials |

A successful response returns `result` or `proxy`. A failed response contains `code`, `message`, `retryable`, and an optional `diagnostic`. Proxy payloads support `status_code`, `content_type`, `url`, `body`, `body_base64`, and string response headers; `status_code` must be between 100 and 599.

The standard Runner mappings are:

| Operation | Standard behavior |
| --- | --- |
| `handshake`, `health`, `cancel`, `shutdown` | Runner-owned lifecycle |
| `init` | `init(ext[, site])` |
| `home`, `home_video` | `homeContent(filter)`, `homeVideoContent()` |
| `category` | `categoryContent(category_id, page, filter, extend)` |
| `search`, `detail` | `searchContent(keyword, quick, page)`, `detailContent(ids)` |
| `player`, `live` | `playerContent(flag, id, vip_flags)`, `liveContent(url)` |
| `proxy`, `action` | `localProxy(parameters)`, `action(action[, value])` |
| `manual_video_check`, `is_video_format`, `destroy` | `manualVideoCheck()`, `isVideoFormat(url)`, `destroy()` |

Protocol v1 and the manifest capability enum declare `epg`, but the current standard CatVod Runners do not map an EPG method. Do not claim `epg` for a standard Runner package. Supporting it requires a signed custom protocol v1 Runner and shell compatibility review.

The source of truth is [provider-wire-v1.schema.json](schema/provider-wire-v1.schema.json) and Swift [`ProviderProtocol.swift`](../NetVplayer/Sources/ProviderSDK/ProviderProtocol.swift).

### Choose a runtime

| Runtime | Current contract |
| --- | --- |
| Python | Python 3 for development; a signed package-local CPython runtime for distribution |
| Java | Java 21 and Gson; a package-local `jlink` image for distribution |
| Node.js | Node.js 22.20.0 with ES modules and `module.registerHooks` |
| QuickJS | Locked QuickJS 2026-06-04 with explicitly declared host capabilities |
| Android Dex | Compatibility assessment only; it remains `needs-port` and cannot run directly on macOS |

Every distributable package declares a package-local `runtime_executable`. Dependencies are signed assets. Runners never call `pip`, fetch remote ES modules, or rely on the user's PATH to complete a production package.

### Manifest and package contract

Manifest v1 is canonical JSON signed with Ed25519. Its main fields are:

| Field | Meaning |
| --- | --- |
| `provider_id`, `version`, `protocol` | Stable identity, version, and protocol `1` |
| `shell_min_version`, `shell_max_version` | Compatible NetVplayer version range |
| `macos_min_version`, `architectures` | Minimum macOS and `arm64` / `x86_64` / `universal2` boundary |
| `runtime`, `runtime_executable` | Runtime kind and package-local executable |
| `entrypoint`, `runner`, `provider_class` | Provider, Runner, and optional entry class |
| `capabilities` | A subset of `vod/home/category/search/detail/player/live/epg/proxy/action` |
| `host_capabilities` | A subset of `console/base64/md5/url/http/jsp/crypto/persistence/text/module/timer/local_proxy` |
| `assets` | Relative path, SHA-256, and executable flag for every package file |
| `source_bindings` | Exact key/API identities from user configuration; no wildcard matching |
| `source_policy` | `user-configured-only` or `user-configured-catalog` |
| `source_revision`, `license`, `status`, `revoked` | Source revision, license, compatibility, and revocation state |
| `sandbox` | App Sandbox v2 launcher, bundle ID, and release-signing profile |

A source-free Python builder-input manifest can start with this shape. Empty asset hashes are placeholders that `build_provider_package.py` replaces with computed SHA-256 values:

```json
{
  "provider_id": "example.python",
  "version": "1.0.0",
  "protocol": 1,
  "shell_min_version": "1.0.0",
  "shell_max_version": null,
  "macos_min_version": "14.0",
  "architectures": ["arm64"],
  "runtime": "python",
  "entrypoint": "provider.py",
  "runner": "provider_runner.py",
  "runtime_executable": "runtimes/cpython/bin/python3",
  "provider_class": "Spider",
  "capabilities": ["home", "category", "search", "detail", "player"],
  "host_capabilities": [],
  "assets": [
    {"path": "provider.py", "sha256": "", "executable": false},
    {"path": "provider_runner.py", "sha256": "", "executable": false},
    {"path": "runtimes/cpython/bin/python3", "sha256": "", "executable": true}
  ],
  "source_bindings": [
    {"original_keys": ["example-user-configured"], "original_apis": []}
  ],
  "source_policy": "user-configured-only",
  "source_revision": "1.0.0",
  "license": "MIT",
  "status": "compatible",
  "revoked": false
}
```

The canonical format is [provider-manifest-v1.schema.json](schema/provider-manifest-v1.schema.json). `build_provider_package.py` adds exactly one managed, non-empty `LICENSES/PROVIDER.txt`; do not list that file in the builder input.

`source_bindings` are exact identities; patterns and wildcards are not evaluated. A normal `user-configured-only` adapter and its bindings must not embed a network authority. The current public shell accepts only `user-configured-only` for automatic installation and manual retry. `user-configured-catalog` is reserved for reviewed adapters that are still triggered by user configuration, requires exact bindings, and needs separate shell and release approval.

The package contains the Provider, Runner, runtime, dependencies, `manifest.json`, `signed-manifest.json`, `signature.ed25519`, `SHA256SUMS`, and exactly one non-empty `LICENSES/PROVIDER.txt`. Every path is relative, contained by the package root, declared in `assets`, and hash matched.

### Development and release workflow

Run the contract tests from the repository root:

```bash
python3 script/test_provider_runners.py -v
python3 script/test_provider_package.py -v
```

Java Runner cases require prebuilt fixture JARs and Gson and are reported as named skips when those inputs are absent. QuickJS has separate contract layers:

```bash
python3 script/test_quickjs_provider_runner.py
python3 script/test_quickjs_provider_golden.py
```

After assembling the complete package-local runtime, Runner, Provider, dependencies, and a non-empty license file, create a disposable development key and build a local package:

```bash
openssl genpkey -algorithm ED25519 \
  -out /private/tmp/netvplayer-provider-dev-key.pem

python3 script/build_provider_package.py \
  --source /absolute/path/to/package-root \
  --manifest /absolute/path/to/manifest.json \
  --license-file /absolute/path/to/PROVIDER-LICENSE.txt \
  --private-key /private/tmp/netvplayer-provider-dev-key.pem \
  --output /private/tmp/example-python-provider.zip

python3 script/validate_provider_package.py \
  /private/tmp/example-python-provider.zip
```

This proves that the manifest, signature, hashes, and ZIP structure can be generated and statically validated. It does not make the official application trust the package and does not satisfy App Sandbox or release acceptance.

Official distribution additionally requires project-approved long-lived manifest/index keys, a pinned HTTPS archive, a signed App Sandbox v2 launcher, package-local runtime version and architecture checks, protocol/catalog/source-policy/revocation/rollback tests, and independent reviews of source and dependency licenses, target service terms, and user authorization. A NetVplayer maintainer must approve the release and add it to the signed distribution index.

Never ask users to replace the application's embedded public keys, disable signature checks, or bypass the pinned index to install a third-party package.

### Troubleshooting

- **`invalid_request` or `unsupported protocol`:** send one complete JSON object per line, use numeric protocol `1`, and match the launched Provider ID.
- **Corrupted JSONL:** write logs to stderr. Keep stdout exclusively for protocol responses.
- **Entrypoint or dependency rejection:** keep every path inside `NETVPLAYER_PROVIDER_ROOT` and declare every file in `assets`; symlinks, path traversal, remote imports, and undeclared files are rejected.
- **Package validates but the app ignores it:** structural validation does not establish trust. The official app accepts only its pinned signed index and approved manifest keys.
- **Credentials:** never store plaintext credentials in code, manifests, logs, or issues. Use explicit user configuration and shell-managed credential references, and redact errors.

## Related documentation

- [Provider Runner implementation reference](../provider-runners/README.md)
- [Project architecture](../ARCHITECTURE.md)
- [Contributing boundary](../CONTRIBUTING.md)
- [Security reporting](../SECURITY.md)
