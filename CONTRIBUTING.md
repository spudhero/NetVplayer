# Contributing

## Public Boundary

The public application must remain source-free. Do not add default source URLs,
video catalogs, live channel lists, site-specific Provider implementations,
accounts, credentials, captured responses, signing keys, or built Provider
packages to the application or public repository.

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

Changes to packaging or distribution must also generate a clean public export
and pass `script/audit_provider_public_release.py`. Test the resulting `.app`,
not a bundle built from a private development checkout.

## Reports

Public issues must not include cookies, authorization headers, signed media
URLs, private endpoints, account data, raw configuration contents, or private
Provider source. Attach only the minimum redacted diagnostic needed to reproduce
the problem.
