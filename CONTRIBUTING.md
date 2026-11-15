# Contributing

## Public Boundary

The public application must remain source-free. Do not add default source URLs,
video catalogs, live channel lists, site-specific Provider implementations,
accounts, credentials, captured responses, signing keys, or built Provider
packages to the application or public repository.

The app-owned Android dialog renderer is a narrowly reviewed exception for compiled
application code. Its [public source and build guide](android-presentation/README.md)
describe the pinned archive, source provenance and dependency checks. This exception
does not allow Provider JARs, host APKs or Android runtimes in the public application.
Keep internal experiment records and agent configuration outside the public export.

Provider execution belongs behind the signed package protocol and App Sandbox
launcher. Configuration data must not become an alternate path for downloading
or executing arbitrary code.

## Verification

Run the focused tests for your change, followed by the serial Swift suite:

```bash
swift test --package-path NetVplayer --disable-sandbox --no-parallel
python3 script/test_provider_public_shell.py --gson-jar /path/to/gson-2.11.0.jar
git diff --check
```

The serial suite supports Xcode 16.4 and later. The opt-in installed-session Apple
translation test requires Xcode 26 / the macOS 26 SDK as well as macOS 26 and
installed language assets. Older toolchains report that test as disabled; this is
not evidence of a successful real-service translation run.

The signed sandbox home-isolation integration requires the real macOS account
home: sandbox home-relative entitlements cannot use a temporary `HOME`. Run it
explicitly from a normal user session, without a `HOME` or `CFFIXED_USER_HOME`
override:

```bash
NETVPLAYER_RUN_SIGNED_SANDBOX_HOME_TEST=1 swift test --package-path NetVplayer \
  --disable-sandbox --no-parallel \
  --filter signedSandboxAuditExecutesHomeWithoutReadingOrChangingOrdinaryState
```

This test creates and removes UUID-scoped fixture Provider, state and container
directories. Ordinary isolated-home test runs report it as skipped; record its
separate result when validating sandbox changes.

Changes to packaging or distribution must also generate a clean public export
and pass `script/audit_provider_public_release.py`. Test the resulting `.app`,
not a bundle built from a private development checkout.
The exporter runs this complete source audit, including presentation provenance and
tracked Markdown file targets. Its source-audit success does not imply Swift or
real-service tests ran; those results are reported separately.

Official macOS releases use a `MAJOR.MINOR.PATCH` tag on `main`. The tag must
match `CFBundleShortVersionString`; the build number must also advance. Pushing
the tag triggers the release workflow, which creates a draft only after the packaged
and re-extracted application passes architecture, version, signature, SBOM,
checksum, and source-free checks. Publishing that reviewed draft is a separate step.

Public releases also require the project's TMDB application credential. Follow
[TMDB setup](TMDB_SETUP.md) to apply and configure the repository Secret. The
release workflow verifies online movie/TV metadata before packaging and checks
the credential in the re-extracted application before publication.

## Reports

Public issues must not include cookies, authorization headers, signed media
URLs, private endpoints, account data, raw configuration contents, or private
Provider source. Attach only the minimum redacted diagnostic needed to reproduce
the problem.
