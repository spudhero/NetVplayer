# Publication identity

Choose the Git identity by repository owner. The internal `chang-chaunce/NetVplayer`
repository uses its internal identity. All `spudhero/*` repositories, including
private Provider sources, use `spudhero` and its GitHub noreply email.

After cloning a publication checkout, install the repository-local identity and
commit/push checks:

```sh
python3 script/validate_publication_identity.py --install-hooks
```

Public and private source exporters install these checks automatically. The
installer preserves unrelated Git configuration and refuses to overwrite existing
hooks or a custom hooks path. Integrate the guard into existing hooks when needed.

Before publishing, check the effective author and committer, reachable history,
annotated taggers, and authenticated GitHub account:

```sh
python3 script/validate_publication_identity.py --github-account
```

The hooks reject identity overrides, personal coauthor trailers in publication
repositories, pushes to another owner, and annotated tags with incorrect taggers.
The CI audit checks all fetched branches and tags without depending on a runner's
local Git identity. Existing releases and legitimate external contributors remain
part of the history. Provider index publishers specify both author and committer
and verify the account before changing a release or index.

Local hooks can be bypassed with Git's override options; the independent CI and
release checks still catch incorrect reachable publication metadata. A new manual
clone must install the hooks before creating commits.

If GitHub's homepage Contributors sidebar disagrees with audited history and the
contributors API after approximately 24 hours, contact GitHub Support with those
two independent results. Preserve release tags and assets: rewriting correct
history does not repair GitHub's cached contributor display.
