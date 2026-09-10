# WebTorrent license supplements

Some locked npm archives declare an SPDX license in `package.json` but do not
ship a standalone license file or the complete text in their README. The
adjacent `supplements.json` binds those exact package archives and installed
metadata hashes to canonical SPDX license text and the attribution published by
the package.

The canonical templates are copied from `spdx/license-list-data` commit
`5bf6d9610255540bfbee6890765a616042bf1e11`. Placeholder fields remain unchanged
apart from normalized trailing whitespace in the BSD template; the package-specific
attribution is recorded in the manifest instead of being invented inside the text.

These supplements are distribution assets, not permission to change a package's
declared license. A conflicting declaration must be removed or replaced rather
than added to this list.
