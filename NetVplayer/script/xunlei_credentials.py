#!/usr/bin/env python3
"""Save and refresh local Xunlei credentials without exposing values in arguments or logs."""
from __future__ import annotations

import argparse
import getpass
import json
import math
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

DEFAULT_CREDENTIAL_FILE = Path.home() / ".config/netvplayer/thunder.env"
TOKEN_ENDPOINT = "https://open.xunlei.com/api/v1/sdk/login_token"
KEYCHAIN_HELPER = Path(__file__).with_name("xunlei_keychain.swift")


class CredentialError(Exception):
    pass


def keychain(operation: str, value: dict[str, str] | None = None) -> dict:
    result = subprocess.run(
        ["/usr/bin/swift", str(KEYCHAIN_HELPER), operation],
        input=json.dumps(value).encode() if value is not None else None,
        capture_output=True, timeout=60,
    )
    if result.returncode:
        diagnostic = result.stderr.decode(errors="replace").strip()
        match = re.fullmatch(r"Xunlei credential operation failed: (console-access|console-copy|invalid-input|keychain--?\d+)", diagnostic)
        stage = match.group(1) if match else "local-helper"
        raise CredentialError(f"Xunlei configuration failed at {stage}; no credentials were printed.")
    return json.loads(result.stdout)


def file_key(path: Path) -> dict[str, str]:
    """Read literal assignments only. Never execute a credential file as code."""
    values: dict[str, str] = {}
    aliases = {"APP_ID": "app_id", "API_KEY": "api_key",
               "NETVPLAYER_XUNLEI_APP_ID": "app_id", "NETVPLAYER_XUNLEI_API_KEY": "api_key"}
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        name, separator, value = line.partition("=")
        target = aliases.get(name.strip().upper())
        if not separator or target is None:
            raise CredentialError("Credential file contains an unsupported assignment.")
        value = value.strip()
        if len(value) >= 2 and value[0] in "\"'" and value[-1] == value[0]:
            value = value[1:-1]
        if not value or any(char in value for char in ["\r", "\n", "\0", "`", "$", "*", "•", "●"]):
            raise CredentialError("Credential file contains an empty, masked or nonliteral value.")
        if target in values:
            raise CredentialError("Credential file contains duplicate assignments.")
        values[target] = value
    if set(values) != {"app_id", "api_key"}:
        raise CredentialError("Credential file requires App ID and API key assignments.")
    return values


def token_credentials(response: dict, app_id: str, issued_at: int) -> dict:
    data = response.get("data")
    if response.get("code") != 0 or not isinstance(data, dict):
        raise CredentialError("The official login-token endpoint rejected the request.")
    token, lifetime = data.get("token"), data.get("expires_in")
    if not isinstance(token, str) or not token.strip():
        raise CredentialError("The official endpoint returned no usable token.")
    if isinstance(lifetime, bool) or not isinstance(lifetime, (int, float)) or not math.isfinite(lifetime) or lifetime <= 60:
        raise CredentialError("The official endpoint returned no usable token lifetime.")
    return {"app_id": app_id, "login_token": token,
            "issued_at": issued_at, "expires_in": int(lifetime), "refresh_authorized": True}


def write_credentials(destination: Path, credentials: dict) -> None:
    destination.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".credentials-", dir=destination.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as stream:
            json.dump(credentials, stream)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, destination)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--credential-file", type=Path, default=DEFAULT_CREDENTIAL_FILE,
                        help="Local literal credential file (default: ~/.config/netvplayer/thunder.env).")
    parser.add_argument("--save-file", action="store_true",
                        help="Save the credential file to Keychain without any network request.")
    parser.add_argument("--save-key", action="store_true",
                        help="Save an interactively supplied App ID and API key to the keychain.")
    parser.add_argument("--refresh", action="store_true",
                        help="Refresh the runtime token using the environment, credential file, or Keychain.")
    options = parser.parse_args()
    try:
        if options.save_file:
            keychain("write", file_key(options.credential_file))
            print("Saved credential-file App ID and API key in the local keychain; no network request.")
        elif options.save_key:
            app_id = input("Xunlei App ID: ").strip()
            api_key = getpass.getpass("Xunlei API Key: ").strip()
            if not app_id or not api_key:
                raise CredentialError("App ID and API key are required.")
            keychain("write", {"app_id": app_id, "api_key": api_key})
            print("Saved NetVplayer App ID and API key in the local keychain.")

        if options.refresh or not (options.save_file or options.save_key):
            app_id = os.environ.get("NETVPLAYER_XUNLEI_APP_ID", "").strip()
            api_key = os.environ.get("NETVPLAYER_XUNLEI_API_KEY", "").strip()
            if not app_id or not api_key:
                saved = file_key(options.credential_file) if options.credential_file.is_file() else keychain("read")
                app_id, api_key = saved["app_id"], saved["api_key"]
            request = urllib.request.Request(TOKEN_ENDPOINT, data=b"", method="POST",
                headers={"Accept": "application/json", "x-api-key": api_key})
            try:
                with urllib.request.urlopen(request, timeout=20) as response:
                    payload = json.load(response)
            except urllib.error.HTTPError as error:
                raise CredentialError(f"Login-token request returned HTTP {error.code}.") from None
            except (urllib.error.URLError, ValueError):
                raise CredentialError("Login-token request failed; no response body was printed.") from None
            credentials = token_credentials(payload, app_id, int(time.time()))
            destination = Path.home() / "Library/Application Support/NetVplayer/ThunderDownload/credentials.json"
            write_credentials(destination, credentials)
            print(f"Configured runtime token; lifetime={credentials['expires_in']} seconds, file mode=0600.")
        return 0
    except CredentialError as error:
        print(str(error), file=sys.stderr)
        return 1
    except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError, KeyError):
        print("Xunlei credential configuration failed; credential values were not printed.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
