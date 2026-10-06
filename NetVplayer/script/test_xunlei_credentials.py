import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("xunlei_credentials", Path(__file__).with_name("xunlei_credentials.py"))
credentials = importlib.util.module_from_spec(spec)
spec.loader.exec_module(credentials)


class XunleiCredentialTests(unittest.TestCase):
    def test_user_file_aliases_and_literal_quotes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "thunder.env"
            path.write_text('APP_ID=fixture\nAPI_key="fixture-key-123456789"\n')
            self.assertEqual(credentials.file_key(path), {"app_id": "fixture", "api_key": "fixture-key-123456789"})

    def test_shell_code_masked_duplicate_or_missing_values_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "thunder.env"
            for text in ['APP_ID=fixture\nAPI_KEY=$(printenv)', 'APP_ID=fixture\nAPI_KEY=`printenv`',
                         'APP_ID=fixture\nAPI_KEY=***', 'APP_ID=fixture',
                         'APP_ID=fixture\nAPI_KEY=fixture\nAPI_key=duplicate']:
                path.write_text(text)
                with self.assertRaises(credentials.CredentialError):
                    credentials.file_key(path)

    def test_token_lifetime_is_server_reported_and_finite(self):
        for lifetime in [True, 0, -1, 60, float("nan"), float("inf"), "3600"]:
            with self.assertRaises(credentials.CredentialError):
                credentials.token_credentials({"code": 0, "data": {"token": "fixture", "expires_in": lifetime}}, "fixture", 10)
        token = credentials.token_credentials({"code": 0, "data": {"token": "fixture", "expires_in": 3600}}, "fixture", 10)
        self.assertEqual(token["expires_in"], 3600)

    def test_runtime_token_is_atomic_private_and_does_not_contain_api_key(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state" / "credentials.json"
            token = credentials.token_credentials({"code": 0, "data": {"token": "fixture", "expires_in": 3600}}, "fixture", 10)
            credentials.write_credentials(path, token)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertTrue(json.loads(path.read_text())["refresh_authorized"])
            self.assertNotIn("api_key", path.read_text())
            self.assertEqual(list(path.parent.iterdir()), [path])


if __name__ == "__main__":
    unittest.main()
