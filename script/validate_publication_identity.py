#!/usr/bin/env python3
"""Keep Git publication identities tied to the repository owner."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
from urllib.parse import urlsplit


IDENTITIES = {
    "chang-chaunce": ("chaunce", "chang.chaunce@gmail.com"),
    "spudhero": ("spudhero", "318930237+spudhero@users.noreply.github.com"),
}
HOOK_MARKER = "# NetVplayer publication identity guard"


class IdentityError(ValueError):
    pass


def git(repo: Path, *args: str, environment: dict[str, str] | None = None) -> str:
    result = subprocess.run(["git", *args], cwd=repo, env=environment,
                            text=True, capture_output=True)
    if result.returncode:
        # Do not print remote URLs or credential-bearing Git diagnostics.
        raise IdentityError(f"Git identity check failed: {args[0]}")
    return result.stdout.strip()


def remote_owner(url: str) -> str:
    if "://" in url:
        parsed = urlsplit(url)
        host, path = parsed.hostname, parsed.path.lstrip("/")
    else:
        match = re.fullmatch(r"(?:[^@/]+@)?([^:/]+):(.+)", url)
        if not match:
            raise IdentityError("publication remote must be a GitHub repository")
        host, path = match.groups()
    if host not in {"github.com", "github-spudhero"}:
        raise IdentityError("publication remote must be a recognized GitHub host")
    parts = path.rstrip("/").removesuffix(".git").split("/")
    if len(parts) != 2 or not all(parts):
        raise IdentityError("invalid GitHub repository path")
    return parts[0].lower()


def repository_owner(repo: Path, expected: str | None = None) -> str:
    remotes = git(repo, "remote").splitlines()
    if "origin" in remotes:
        owner = remote_owner(git(repo, "remote", "get-url", "origin"))
        if expected and expected != owner:
            raise IdentityError("origin owner disagrees with the requested publication owner")
    elif expected:
        owner = expected  # A new export has no origin yet.
    else:
        raise IdentityError("origin is missing; specify the owner for a new export")
    if owner not in IDENTITIES:
        raise IdentityError("no publication identity configured for this repository owner")
    return owner


def parse_identity(value: str) -> tuple[str, str]:
    match = re.fullmatch(r"(.+?) <([^<>]+)>(?: \d+ [+-]\d{4})?", value.strip())
    if not match:
        raise IdentityError("invalid Git identity")
    return match.group(1), match.group(2)


def require_current_identity(repo: Path, owner: str,
                             environment: dict[str, str] | None = None) -> None:
    for role in ("AUTHOR", "COMMITTER"):
        actual = parse_identity(git(repo, "var", f"GIT_{role}_IDENT", environment=environment))
        if actual != IDENTITIES[owner]:
            raise IdentityError(f"{role.lower()} must use the {owner} repository identity")


def require_no_personal_identity(value: str, context: str) -> None:
    name, email = parse_identity(value)
    if name.casefold() in {"chaunce", "chang-chaunce"} or email.casefold() == IDENTITIES["chang-chaunce"][1]:
        raise IdentityError(f"personal identity found in {context}")


def check_message(message: str, owner: str) -> None:
    if owner != "spudhero":
        return
    for line in message.splitlines():
        match = re.match(r"^Co-authored-by:\s*(.+)$", line, flags=re.IGNORECASE)
        if match:
            require_no_personal_identity(match.group(1), "coauthor trailer")


def check_tag(repo: Path, object_id: str, owner: str, *, new_tag: bool = False) -> None:
    if git(repo, "cat-file", "-t", object_id) != "tag":
        return
    header = git(repo, "cat-file", "tag", object_id).split("\n\n", 1)[0]
    tagger = next((line[7:] for line in header.splitlines() if line.startswith("tagger ")), None)
    if not tagger:
        raise IdentityError("annotated publication tag has no tagger")
    if owner == "spudhero":
        require_no_personal_identity(tagger, "annotated tagger")
    if new_tag and parse_identity(tagger) != IDENTITIES[owner]:
        raise IdentityError(f"new annotated tagger must use the {owner} repository identity")
    target = next(line[7:] for line in header.splitlines() if line.startswith("object "))
    if git(repo, "cat-file", "-t", target) == "tag":
        check_tag(repo, target, owner, new_tag=new_tag)


def audit_history(repo: Path, owner: str, extra_objects: list[str] | None = None) -> int:
    if owner != "spudhero":
        return 0  # Preserve imported internal history; new local identities are checked separately.
    revisions = ["--all"]
    if subprocess.run(["git", "rev-parse", "--verify", "HEAD"], cwd=repo,
                      capture_output=True).returncode == 0:
        revisions.append("HEAD")
    revisions.extend(extra_objects or [])
    commits = git(repo, "rev-list", *revisions).splitlines()
    for commit in commits:
        fields = git(repo, "show", "-s", "--format=%an <%ae>%n%cn <%ce>%n%B", commit).split("\n", 2)
        author, committer = fields[:2]
        message = fields[2] if len(fields) == 3 else ""
        require_no_personal_identity(author, f"author of {commit}")
        require_no_personal_identity(committer, f"committer of {commit}")
        check_message(message, owner)
    for tag in git(repo, "for-each-ref", "--format=%(objectname)", "refs/tags").splitlines():
        check_tag(repo, tag, owner)
    return len(commits)


def require_github_account(owner: str) -> None:
    result = subprocess.run(["gh", "api", "user", "--jq", ".login"],
                            text=True, capture_output=True)
    if result.returncode or result.stdout.strip().casefold() != owner:
        raise IdentityError(f"authenticated GitHub account must be {owner}")


def publication_commit_fields(owner: str) -> dict[str, dict[str, str]]:
    name, email = IDENTITIES[owner]
    return {role: {"name": name, "email": email} for role in ("author", "committer")}


def configure_identity(repo: Path, owner: str) -> None:
    name, email = IDENTITIES[owner]
    git(repo, "config", "--local", "user.name", name)
    git(repo, "config", "--local", "user.email", email)


def install_hooks(repo: Path, owner: str) -> None:
    custom_hooks = subprocess.run(["git", "config", "--get", "core.hooksPath"], cwd=repo,
                                 capture_output=True, text=True)
    if custom_hooks.returncode == 0:
        raise IdentityError("custom core.hooksPath requires integration; it was not changed")
    hook_dir = Path(git(repo, "rev-parse", "--git-path", "hooks"))
    if not hook_dir.is_absolute():
        hook_dir = repo / hook_dir
    hooks = {
        "pre-commit": '--current-only',
        "commit-msg": '--current-only --commit-message "$1"',
        "pre-push": '--pre-push "$2"',
    }
    # Inspect all existing hooks before making any changes; never replace another tool's hooks.
    for name in hooks:
        path = hook_dir / name
        if path.exists() and HOOK_MARKER not in path.read_text():
            raise IdentityError(f"existing {name} hook requires integration; it was not replaced")
    configure_identity(repo, owner)
    hook_dir.mkdir(parents=True, exist_ok=True)
    guard = hook_dir / "netvplayer_identity_guard.py"
    if guard.resolve() != Path(__file__).resolve():
        shutil.copy2(Path(__file__), guard)
    for name, arguments in hooks.items():
        path = hook_dir / name
        path.write_text(
            '#!/bin/sh\n' + HOOK_MARKER + '\n'
            'hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1\n'
            f'exec python3 "$hook_dir/netvplayer_identity_guard.py" --repo . --owner {owner} {arguments}\n'
        )
        path.chmod(0o755)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path("."))
    parser.add_argument("--owner", choices=IDENTITIES)
    parser.add_argument("--history-only", action="store_true", help="CI audit without local author configuration")
    parser.add_argument("--current-only", action="store_true")
    parser.add_argument("--commit-message", type=Path)
    parser.add_argument("--pre-push", metavar="REMOTE_URL")
    parser.add_argument("--github-account", action="store_true")
    parser.add_argument("--install-hooks", action="store_true")
    args = parser.parse_args()
    repo = args.repo.resolve()
    owner = repository_owner(repo, args.owner)
    if args.install_hooks:
        install_hooks(repo, owner)
    if not args.history_only:
        require_current_identity(repo, owner)
    if args.github_account:
        require_github_account(owner)
    objects: list[str] = []
    if args.pre_push:
        if remote_owner(args.pre_push) != owner:
            raise IdentityError("push destination owner disagrees with origin")
        for line in sys.stdin:
            local_ref, local_id, _, remote_id = line.split()
            if set(local_id) == {"0"}:
                continue  # A deletion introduces no commit or tag identity.
            objects.append(local_id)
            if local_ref.startswith("refs/tags/") and local_id != remote_id:
                check_tag(repo, local_id, owner, new_tag=True)
    if args.commit_message:
        check_message(args.commit_message.read_text(), owner)
    count = 0 if args.current_only else audit_history(repo, owner, objects)
    print(json.dumps({"ok": True, "owner": owner, "audited_commits": count,
                      "hooks_installed": args.install_hooks}, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (IdentityError, OSError) as error:
        print(f"Publication identity: {error}", file=sys.stderr)
        raise SystemExit(1)
