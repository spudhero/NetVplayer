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

The native HTTP-failure audit creates an OpenGL playback surface and requires a
graphical macOS session with libmpv. Enable its three local HTTP fixtures with
`NETVPLAYER_RUN_NATIVE_AUDIT_INTEGRATION=1` and filter
`nativeMediaFailureReportsOnlyObservedHTTPStatus`. Headless CI reports this
integration as disabled and still runs the audit ownership and status contracts.
CI runs the serial suite through `script/run_swift_regression.py`; five minutes
without output collects owned test process stacks and fails the run, preserving
the evidence needed to diagnose a stall.
It also requires a completion summary for every Swift Testing run: an early zero
exit is a failed gate, even if earlier tests and XCTest suites passed.

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
checksum, and source-free checks. It also launches the extracted app in its isolated
visual mode with the SwiftPM build resource fallback temporarily hidden, and requires
a rendered capture. The probe restores the build resources on failure as well as
success; moving those resources is restricted to an isolated CI runner. Publishing
that reviewed draft is a separate step.

Before fixing the official tag, the `Release macOS app` workflow can prepare the
same verified assets manually from `main`, with the application version as its
`version` input. The exact commit must pass the public gate before packaging, and the
repository owner must have created an empty unpublished draft for that version.
Preparation may wait up to 30 minutes for an active gate on that same commit;
a failed, cancelled, missing or overdue gate prevents packaging.
Preparation only uploads to that draft; it creates no Git tag and publishes no
release. Record the draft's source commit and asset digests before approval.
When the official tag points to that exact commit, the tag workflow compares the
successful preparation run's original artifact with every draft asset and reuses
those bytes. It fails on a changed asset instead of rebuilding a reviewed package.
The original workflow artifact is retained for 14 days.
Before creating the tag, run the same workflow with `verify_prepared=true` to
exercise that comparison. This mode requires a successful original preparation
and skips all build and upload jobs after matching the draft.

Preparation and pinned-runtime transfer use the supported `macos-15` runner.
The runtime and extracted application retain independent Mach-O checks for a
maximum deployment target of macOS 14.0; these checks do not claim a macOS 14
hardware acceptance run.

Public releases also require the project's TMDB application credential. Follow
[TMDB setup](TMDB_SETUP.md) to apply and configure the repository Secret. The
release workflow verifies online movie/TV metadata before packaging and checks
the credential in the re-extracted application before publication.

## Reports

Public issues must not include cookies, authorization headers, signed media
URLs, private endpoints, account data, raw configuration contents, or private
Provider source. Attach only the minimum redacted diagnostic needed to reproduce
the problem.

Loopback tests stop their own child processes with bounded termination and a
verified exit. Use `stopOwnedFixtureProcess` for these fixtures; unbounded
`Process.waitUntilExit()` can pump a nested run loop and stall the main actor.
The real-process contracts cover graceful exit, ignored SIGTERM, isolation of
a separate child and repeated cleanup.

On macOS the regression runner sets `NSUnbufferedIO=YES` for its child so
Foundation stdout reaches the idle watchdog promptly. The 300-second idle
deadline and the requirement for every started run's completion remain intact.

Playback state-machine fixtures that submit through `playSpecHandler` must
isolate their simulated state from the real engine's asynchronous stop reset.
Use the production refresh budget and assert the loading phase before sending
EOF; a shortened deadline must not expire during unrelated playback setup.

Diagnostic JSON must contain concrete numbers or strings: resolve optional
values before mixing them into `[String: Any]`. Existing platform compatibility
notices cover noninteractive legacy Keychain reads, the explicit Sentry app-hang
opt-out, and the sniffer's bounded fire-and-forget JavaScript poll. Those calls
retain their current migration, privacy, and session-lifetime behavior.
Keep task completion awaits when discarding their result; spell the discard as
`_ = await task.value` so cleanup retains its ordering.
Keep a failable Metal surface initializer separate from NSView's nonnull
`initWithFrame:` contract; callers must retain the nil fallback. Remove `try`
from nonthrowing actor calls even inside Testing macros, whose diagnostics can
otherwise appear only at the macro expansion rather than the source call.

When testing coalesced network reports, hold the fixture response until every
update and the terminal stop have been submitted, then release it explicitly.
A short sleep cannot establish that ordering on a loaded runner. Assert the
exact Started / latest Progress / Stopped sequence and final positions.

For hover prefetch tests, wait for the observed Provider call within a bounded
deadline before checking its exact count. The 250 ms UI debounce plus a fixed
sleep does not guarantee actor scheduling. Keep the Android-original negative
case separate: hovering must make zero calls before the explicit card click.
