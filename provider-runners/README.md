# NetVplayer Provider runners

These helpers implement protocol v1 over newline-delimited JSON on stdin/stdout. Provider logs are redirected to stderr so they cannot corrupt the wire stream.

- `python/provider_runner.py` supports the complete CatVod lifecycle and package-local dependencies.
- `js/provider_runner.mjs` supports ES modules and the same lifecycle. It requires Node.js with `module.registerHooks`; the public POC pins Node 22.20.0 because earlier Node 22 builds can pass a major-version check while lacking that API. Production manifests should declare a signed package-local `runtime_executable` instead of relying on the user's PATH.
- `quickjs/provider_runner.mjs` uses the locked QuickJS 2026-06-04 runtime and capability-gated Swift hosts. It keeps JSONL stdout protocol-only, applies a bounded single-in-flight host queue, validates package-local modules, and rejects dynamic network imports, CommonJS, and package escapes.
- `java/` contains the Java 21 interface, reflection adapter, runner, build definition, and two fixtures: a no-network mock plus a standard-Java JSON CMS provider that is exercised against a local redacted HTTP service.

Production packages must declare every runner, runtime, provider, and dependency asset in the signed manifest. The helpers reject entrypoints outside `NETVPLAYER_PROVIDER_ROOT`; they do not download code or install dependencies at runtime.

Manifest templates for the three POC packages live beside their fixtures:

- `java/fixtures/manifest.template.json`
- `js/fixtures/manifest.template.json`
- `python/fixtures/manifest.template.json`

Private CI fills the asset hashes after assembling the package-local JRE, Node-compatible runtime, or CPython image. Run `python3 script/validate_provider_package.py /path/to/provider.zip` after `script/build_provider_package.py`; this structural gate rejects undeclared payloads, metadata drift, missing runtime executables, path traversal, and digest mismatches. It does not replace the shell's Ed25519 verification.

The Python and JS fixtures each load one package-local dependency, so the
matrix also exercises import resolution without any remote module or `pip`
installation.

The reproducible POC entry point is `script/test_provider_runtime_matrix.py`. It
requires `NETVPLAYER_GSON_JAR` (or `--gson-jar`), builds both Java fixtures,
executes four Java/JS/Python Runner lifecycles, assembles temporary Java/JS/Python
packages, validates them, extracts them, and repeats the lifecycle through each
manifest-selected package-local runtime. The matrix also runs package/catalog
tests and records the Android/Dex audit as JSON. Its Java and package results
are explicitly host-runtime POC evidence;
production CI must still provide a Java 21 `jlink` image and package-local JS
and CPython runtimes.

QuickJS has its own contract layers rather than sharing the Node POC matrix:

```bash
python3 script/test_quickjs_provider_runner.py
python3 script/test_quickjs_provider_golden.py
python3 script/test_quickjs_android_golden.py
python3 script/test_private_bili_script_providers.py
```

The signed Bili QuickJS package additionally runs through the generated App
Sandbox launcher and the product Swift HTTP host. See
`NetVplayer/Docs/quickjs_compatibility_plan_20260823.md` for the evidence matrix.
The public package fixture is assembled by `script/test_provider_package.py`;
site-specific QuickJS manifest templates stay in the private Provider source.

Private CI must run `script/validate_node_runtime.py` against the assembled JS
runtime and `script/validate_cpython_runtime.py` against CPython. The Node gate
allows package-relative Mach-O references and Apple system libraries, but
rejects unresolved `@rpath` entries and absolute Homebrew/package-manager
dylibs. Official single-binary Node distributions are supported; `libnode` is
included only when the selected runtime actually ships it separately.

The Java image must pass `script/validate_java_runtime.py --version 21`. This
checks that `bin/java` and the reported `java.home` stay inside the signed
runtime, verifies the major version, and applies the same Mach-O dependency
gate to every executable and dylib in the `jlink` image.

The CPython gate verifies isolated `sys.executable`, `sys.prefix`,
`sys.base_prefix`, every `sys.path` entry, and all packaged Mach-O dependencies.
The public POC reports `host-dependent` when a copied host Python or Node still
resolves package-manager assets; execution success never upgrades that status.
