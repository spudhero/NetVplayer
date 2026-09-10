# NetVplayer

NetVplayer 1.0.0 is a native macOS SwiftUI media player built around embedded
libmpv. The public application is source-free: it ships without video catalogs,
live channel lists, site-specific Providers, accounts, or default source URLs.

Users may add their own compatible configuration, WebDAV, AList/OpenList, or
supported cloud-drive account. A saved user configuration can be restored on a
later launch; a new installation remains empty until the user adds one. On
startup, the app automatically downloads and activates compatible Provider
support packages before loading a saved or newly entered configuration.

## Provider Security

Provider integrations are separate packages. NetVplayer accepts packages
only from its pinned HTTPS index and verifies the index signature, archive hash,
manifest signature, protocol, application version, macOS version, architecture,
declared assets, sandbox launcher, and revocation state before activation.

Automatic installation additionally requires the signed manifest policy
`user-configured-only`. Stable build artifacts cover all 50 private Provider
manifests through compiled Python, Java, Node.js, and QuickJS runtime packages,
plus the configurable HBPQ/iBox compatibility package. A Provider is selected
only after a user-supplied configuration matches its exact key or API identity.
The user's configuration URL, site list, accounts, and credentials are not
packaged. Provider development source and history remain in the private source
repository; the distribution repository contains signed build artifacts only.
A separate diagnostics channel tests the download and sandbox lifecycle.

## Requirements

- macOS 14 or later
- Apple Silicon for the current 1.0.0 release
- Xcode and Homebrew libmpv dependencies when building from source

## Build And Test

```bash
swift build --package-path NetVplayer
swift test --package-path NetVplayer --disable-sandbox --no-parallel
```

Create an isolated source-free release bundle:

```bash
bash NetVplayer/script/build_and_run.sh \
  --package-public /absolute/path/to/output
```

The release command rejects a dirty public checkout and extra source/resource
inputs, builds in release mode, verifies bundled runtime licenses and SBOM data,
signs the bundle with the community ad-hoc profile, and audits the final `.app`
for source payloads. It does not replace or launch `/Applications/NetVplayer.app`.

## Repository Layout

- `NetVplayer/`: application and Swift packages
- `provider-sdk/`: public wire, manifest, catalog, and distribution schemas
- `provider-runners/`: public Java, JavaScript, QuickJS, and Python runner contracts
- `script/`: build, package, signature, sandbox, and release checks

See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md) before
submitting changes or diagnostics.

## License

NetVplayer is released under the [MIT License](LICENSE). Bundled third-party
components retain their own licenses and notices.
