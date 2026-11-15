#!/usr/bin/env python3
"""Offline AI-drama registration, isolation, and cache regressions."""
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
from urllib.parse import parse_qs, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "private-providers/aidj-python"))
import aidj_device as device


RESPONSE = {"device_id_str": "123456789", "install_id_str": "987654321",
            "device_token": "not-a-real-token", "cookie": "not-a-real-cookie"}
DEVICES = {"device_id": "123456789", "iid": "987654321"}


class AiDjDeviceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="aidj-device-test-")
        self.addCleanup(self.temporary.cleanup)
        self.state = Path(self.temporary.name)
        self.environment = patch.dict(os.environ, {"NETVPLAYER_PROVIDER_STATE": str(self.state)})
        self.environment.start()
        self.addCleanup(self.environment.stop)
        device._cache.clear()
        self.addCleanup(device._cache.clear)
        self.request = Mock(return_value=json.dumps(RESPONSE).encode())

    @property
    def cache_file(self):
        return self.state / "aidj/device-v2.json"

    def test_registration_contains_fresh_install_identity_and_matching_profile(self):
        with patch.object(device.time, "time", return_value=1700000000):
            first = json.loads(device._registration_payload())
            second = json.loads(device._registration_payload())
        self.assertEqual(first["magic_tag"], "ss_app_log")
        self.assertEqual(first["_gen_time"], 1700000000000)
        header = first["header"]
        self.assertEqual(header["device_model"], device.DEVICE_PROFILE["device_type"])
        self.assertEqual(header["version_code"], int(device.DEVICE_PROFILE["version_code"]))
        self.assertEqual(header["resolution"], "1440x2560")
        for key in ("cdid", "clientudid", "req_id", "openudid"):
            self.assertNotEqual(header[key], second["header"][key])
        self.assertNotIn("device_id", header)
        self.assertNotIn("install_id", header)

    def test_json_registration_matches_query_body_profile_without_account_data(self):
        with patch.object(device.time, "time", return_value=1700000000):
            self.assertEqual(device.ensure_devices(self.request), DEVICES)
        url, headers, body = self.request.call_args.args
        parsed = urlsplit(url)
        self.assertEqual(parsed._replace(query="").geturl(), device.REGISTER_URL)
        params = parse_qs(parsed.query)
        registration = json.loads(body)
        header = registration["header"]
        self.assertEqual(params["aid"], [str(header["aid"])])
        self.assertEqual(params["device_type"], [header["device_model"]])
        self.assertEqual(params["version_name"], [header["app_version"]])
        for name in ("version_code", "manifest_version_code", "update_version_code",
                     "channel", "os_api", "os_version", "device_brand", "req_id"):
            self.assertEqual(params[name], [str(header[name])])
        self.assertEqual(params["_rticket"], [str(registration["_gen_time"])])
        self.assertEqual(params["resolution"], ["1440*2560"])
        self.assertEqual(headers["content-type"], device.REGISTER_TYPE)
        self.assertEqual(set(headers), {"user-agent", "accept", "content-type"})
        self.assertFalse({"device_id", "iid", "install_id", "tt_data"} & params.keys())
        self.assertFalse({"cookie", "device_token", "token"} & header.keys())

    def test_old_registration_cache_is_preserved_and_not_reused(self):
        self.cache_file.parent.mkdir()
        legacy = self.cache_file.with_name("device-v1.json")
        original = json.dumps({"schema": 1, "profile": device.DEVICE_PROFILE,
                               "device_id": "111", "iid": "222"}).encode()
        legacy.write_bytes(original)
        legacy.chmod(0o600)
        self.assertEqual(device.ensure_devices(self.request,
            verify_media=Mock(side_effect=[False, True])), DEVICES)
        self.request.assert_called_once()
        self.assertEqual(legacy.read_bytes(), original)
        self.assertEqual(json.loads(self.cache_file.read_text())["schema"], 2)

    def test_working_legacy_pair_is_verified_and_promoted_without_registration(self):
        self.cache_file.parent.mkdir()
        legacy = self.cache_file.with_name("device-v1.json")
        original = json.dumps({"schema": 1, "profile": device.DEVICE_PROFILE, **DEVICES}).encode()
        legacy.write_bytes(original)
        legacy.chmod(0o600)
        verifier = Mock(return_value=True)
        self.assertEqual(device.ensure_devices(self.request, verify_media=verifier), DEVICES)
        verifier.assert_called_once_with(DEVICES)
        self.request.assert_not_called()
        self.assertEqual(legacy.read_bytes(), original)
        self.assertTrue(json.loads(self.cache_file.read_text())["media_verified"])

    def test_failed_new_registration_preserves_legacy_cache(self):
        self.cache_file.parent.mkdir()
        legacy = self.cache_file.with_name("device-v1.json")
        original = b'{"schema":1,"device_id":"111","iid":"222"}'
        legacy.write_bytes(original)
        self.request.return_value = b""
        with self.assertRaises(device.DeviceRegistrationError):
            device.ensure_devices(self.request)
        self.assertEqual(legacy.read_bytes(), original)
        self.assertFalse(self.cache_file.exists())
        self.assertFalse(device._cache)

    def test_private_atomic_cache_survives_process_cache_reset(self):
        device.ensure_devices(self.request)
        self.assertEqual(stat.S_IMODE(self.cache_file.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.cache_file.parent.stat().st_mode), 0o700)
        self.assertEqual(set(self.cache_file.parent.iterdir()), {self.cache_file})
        value = json.loads(self.cache_file.read_text())
        self.assertEqual(set(value), {"schema", "profile", "device_id", "iid", "media_verified"})
        self.assertEqual(value["schema"], 2)
        self.assertFalse(value["media_verified"])
        self.assertEqual(value["profile"], device.DEVICE_PROFILE)
        self.assertNotIn("not-a-real-token", self.cache_file.read_text())
        device._cache.clear()
        self.request.reset_mock()
        result = device.ensure_devices(self.request)
        self.assertEqual(result, DEVICES)
        self.request.assert_not_called()
        result["device_id"] = "changed-by-caller"
        self.assertEqual(device.ensure_devices(self.request), DEVICES)

    def test_without_provider_state_uses_only_memory(self):
        del os.environ["NETVPLAYER_PROVIDER_STATE"]
        with patch.object(Path, "home", side_effect=AssertionError("must not use HOME")):
            self.assertEqual(device.ensure_devices(self.request), DEVICES)
            self.assertEqual(device.ensure_devices(self.request), DEVICES)
        self.request.assert_called_once()
        self.assertEqual(list(self.state.iterdir()), [])

    def test_unusable_candidate_is_not_cached_and_second_verified_pair_is_reused(self):
        second = {"device_id": "2468", "iid": "1357"}
        self.request.side_effect = [json.dumps(RESPONSE).encode(),
                                   b'{"device_id":2468,"install_id":1357}']
        verifier = Mock(side_effect=[False, True])
        self.assertEqual(device.ensure_devices(self.request, verify_media=verifier), second)
        self.assertEqual(verifier.call_args_list[0].args[0], DEVICES)
        self.assertEqual(self.request.call_count, 2)
        self.assertTrue(json.loads(self.cache_file.read_text())["media_verified"])
        device._cache.clear()
        self.request.reset_mock()
        verifier = Mock(side_effect=AssertionError("verified cache must not be rotated"))
        self.assertEqual(device.ensure_devices(self.request, verify_media=verifier), second)
        self.request.assert_not_called()
        verifier.assert_not_called()

    def test_two_unusable_candidates_stop_without_persisting_them(self):
        with self.assertRaisesRegex(device.DeviceRegistrationError, "暂未就绪"):
            device.ensure_devices(self.request, verify_media=Mock(return_value=False))
        self.assertEqual(self.request.call_count, 2)
        self.assertFalse(self.cache_file.exists())
        self.assertFalse(device._cache)

    def test_pending_catalog_pair_is_validated_before_media_reuse(self):
        device.ensure_devices(self.request)
        device._cache.clear()
        self.request.reset_mock()
        verifier = Mock(return_value=True)
        self.assertEqual(device.ensure_devices(self.request, verify_media=verifier), DEVICES)
        verifier.assert_called_once_with(DEVICES)
        self.request.assert_not_called()
        self.assertTrue(json.loads(self.cache_file.read_text())["media_verified"])

    def test_failed_validation_preserves_pending_cache_bytes(self):
        device.ensure_devices(self.request)
        original = self.cache_file.read_bytes()
        with self.assertRaises(device.DeviceRegistrationError):
            device.ensure_devices(self.request, verify_media=Mock(return_value=False))
        self.assertEqual(self.cache_file.read_bytes(), original)

    def test_structured_error_retains_pending_pair_until_model_is_verified(self):
        self.assertEqual(device.ensure_devices(self.request, verify_media=Mock(return_value=None)), DEVICES)
        self.assertEqual(self.request.call_count, 1)
        self.assertFalse(json.loads(self.cache_file.read_text())["media_verified"])
        self.request.reset_mock()
        self.assertEqual(device.ensure_devices(self.request, verify_media=Mock(return_value=True)), DEVICES)
        self.request.assert_not_called()
        self.assertTrue(json.loads(self.cache_file.read_text())["media_verified"])

    def test_process_cache_is_scoped_to_provider_state(self):
        device.ensure_devices(self.request)
        os.environ["NETVPLAYER_PROVIDER_STATE"] = str(self.state / "another-provider")
        self.request.return_value = b'{"device_id":2468,"install_id":1357}'
        self.assertEqual(device.ensure_devices(self.request), {"device_id": "2468", "iid": "1357"})
        self.assertEqual(self.request.call_count, 2)
        os.environ["NETVPLAYER_PROVIDER_STATE"] = str(self.state)
        self.assertEqual(device.ensure_devices(self.request), DEVICES)

    def test_corrupt_cache_profile_and_extra_secrets_require_registration(self):
        for mutation in (lambda value: {**value, "device_id": "0"},
                         lambda value: {**value, "profile": {}},
                         lambda value: {**value, "schema": 1},
                         lambda value: {**value, "schema": True},
                         lambda value: {**value, "device_token": "untrusted"},
                         lambda value: []):
            with self.subTest(mutation=mutation):
                device._cache.clear()
                device.ensure_devices(self.request)
                value = mutation(json.loads(self.cache_file.read_text()))
                self.cache_file.write_text(json.dumps(value))
                device._cache.clear()
                self.request.reset_mock()
                self.assertEqual(device.ensure_devices(self.request), DEVICES)
                self.request.assert_called_once()
        self.cache_file.chmod(0o644)
        device._cache.clear()
        self.request.reset_mock()
        device.ensure_devices(self.request)
        self.request.assert_called_once()
        self.assertEqual(stat.S_IMODE(self.cache_file.stat().st_mode), 0o600)

    def test_failed_registration_does_not_cache_fake_identifiers(self):
        for response in (b"", b"not-json", b"[]", b"{}",
                         b'{"device_id":0,"install_id":1}',
                         b'{"device_id":true,"install_id":1}',
                         '{"device_id_str":"１２３","install_id":1}'.encode(),
                         b'{"device_id":123,"install_id":-4}'):
            with self.subTest(response=response):
                self.request.return_value = response
                with self.assertRaises(device.DeviceRegistrationError):
                    device.ensure_devices(self.request)
                self.assertFalse(self.cache_file.exists())
                self.assertFalse(device._cache)
        self.request.return_value = json.dumps(RESPONSE).encode()
        self.assertEqual(device.ensure_devices(self.request), DEVICES)

    def test_cache_symlinks_are_rejected_without_touching_target(self):
        target = self.state / "user-data"
        target.write_text("preserve")
        self.cache_file.parent.mkdir()
        self.cache_file.symlink_to(target)
        with self.assertRaises(device.DeviceRegistrationError):
            device.ensure_devices(self.request)
        self.request.assert_not_called()
        self.assertEqual(target.read_text(), "preserve")

    def test_transport_errors_do_not_leak_response_details_or_cache_identifiers(self):
        self.request.side_effect = OSError("private-network-details")
        with self.assertRaises(device.DeviceRegistrationError) as caught:
            device.ensure_devices(self.request)
        self.assertIn("AI 设备注册失败", str(caught.exception))
        self.assertNotIn("private-network-details", str(caught.exception))
        self.assertFalse(self.cache_file.exists())
        self.assertFalse(device._cache)

    def test_interrupted_atomic_write_preserves_existing_file_and_cleans_temporary(self):
        self.cache_file.parent.mkdir()
        self.cache_file.write_text("invalid-old-cache")
        self.cache_file.chmod(0o600)
        with patch.object(device.os, "replace", side_effect=OSError("write interrupted")):
            with self.assertRaisesRegex(device.DeviceRegistrationError, "本地状态"):
                device.ensure_devices(self.request)
        self.assertEqual(self.cache_file.read_text(), "invalid-old-cache")
        self.assertEqual(set(self.cache_file.parent.iterdir()), {self.cache_file})
        self.assertFalse(device._cache)


if __name__ == "__main__":
    unittest.main()
