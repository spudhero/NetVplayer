#!/usr/bin/env python3
"""Offline current-AiDj signing regression vectors from the unmodified JAR.

The vectors use example.invalid and a synthetic gzip body. They were observed by
calling only xq.i / xq.Nl; no account credentials or media endpoints were used.
The fixture retains synthetic inputs, protobuf, random inputs and output digests.
"""
from __future__ import annotations

import base64
import hashlib
import json
from pathlib import Path
import sys
import unittest
from unittest import mock
from urllib.parse import parse_qsl, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'private-providers' / 'aidj-python'))
import aidj_signing as signing

JAVA_VECTORS = json.loads(r'''[
  {
    "url": "https://example.invalid/aidj-offline?device_id=123456789&version_name=7.1.3.32&sample=0&ts=1700000000&_rticket=1700000000000",
    "body_base64": "H4sIAAAAAAAA/6tWyk9Ly8nMS41Py6woKS1KVbIqKSpNrQUAqgOkbRgAAAA=",
    "timestamp": 1700000000,
    "base_rticket": 1700000000000,
    "selected_offset": 0,
    "f13_hex": "b3279bdf43839aeea92234746555911af5eb1d0881d807a34b0967f8984ddedff5db2788",
    "query_prefix_hex": "b3279bdf4383",
    "proto_base64": "ChD36F/619fcO9YqyHBXz2EYEAYYxrqiPyIEODY2MioJMTIzNDU2Nzg5MgoxNTg4MDkzMjI4Ogg3LjEuMy4zMkIUdjA0LjA2LjA0LW1sLWFuZHJvaWRIgJCwQFIIQAEAAAAAAABggMSf1QxqJLMnm99Dg5ruqSI0dGVVkRr16x0IgdgHo0sJZ/iYTd7f9dsniHIGsyeb30ODeg8I3gEQFBi+4VQojrjhrwSCARg3ZzNvcHdycnVYcElfc3JkSlZzenhRZE2IAYDEn9UMmgEg71i+YXOgp7I5u6n6qYzu1MPvq7MAha1OrTXIGitKaGaiAQRub25lqAHwBLoBzAII1gEQjtzGiwEYiNzGiwEoDjITdjA0LjA2LjA0LjAzLWJ1Z2ZpeDjGtwFiiAIIAhAEGgQ4NjYyIgkxMjM0NTY3ODkqGDdnM29wd3JydVhwSV9zcmRKVnN6eFFkTTIIIW5vcGVybSE478BsQO/AbEgGUO/AbFoIIW5vdHNldCFiD0FzaWEvU2hhbmdoYWksOGoFemhfQ05wCIUBAAAAAI0BAAAAAJUBAAAAAJ0BAAAAAKUBAAAAAK0BAAAAALIBAjE2uAFSwAFIyAGerJ2QuWjQAZ6snZC5aNgBnqydkLlo4AGerJ2QuWjoAQHyAQoyNTA1M1JUNDdD+gEFUmVkbWmCAgoyNTA1M1JUNDdDigIKMjUwNTNSVDQ3Q5ICBlhpYW9taZoCBVJlZG1pogIFUmVkbWmwAj5qCwj+4p+vDRADIJADcgg3LjEuMy4zMsIBfXsiY21yIjoxNjc3NzIxNiwiY21yMiI6MTY3NzcyMTYsInVuX2giOjE4NzkxOTQwNDAsInZwbiI6MCwia2QiOjAsImZrZCI6MzY3MjUxODk3MiwicGQiOi0xODcyNTczMjQ3LCJkeW4iOiIiLCJkbyI6MCwidGsiOnRydWV9",
    "xm_rand": 1990980462,
    "gorgon_rand": 56204,
    "gorgon_sha256": "40ff113414920a639c56dc2b0b28059e10dcee10e7fce08aa48384f3c3c9d4d4",
    "helios_rand": 2799267034,
    "helios_sha256": "03610066fbaa8535e34809c483ae143b00cd0c871740d1387c61680316362ee8",
    "hash_rand": 3480093316,
    "medusa_sha256": "42a50c4196cb3e2bb576a48f52383d6bc2f7a9a273c2773209753a68846f8713"
  },
  {
    "url": "https://example.invalid/aidj-offline?device_id=123456789&version_name=7.1.3.32&sample=1&ts=1700000001&_rticket=1700000001100",
    "body_base64": "H4sIAAAAAAAA/6tWyk9Ly8nMS41Py6woKS1KVbIqKSpNrQUAqgOkbRgAAAA=",
    "timestamp": 1700000001,
    "base_rticket": 1700000001100,
    "selected_offset": 0,
    "f13_hex": "fb6d7fc0532b7d0b44973105bacf29aef5eb1d0881d807a34b0967f8984ddedf441bedb0",
    "query_prefix_hex": "fb6d7fc0532b",
    "proto_base64": "ChD36F/619fcO9YqyHBXz2EYEAYY5pmrvAUiBDg2NjIqCTEyMzQ1Njc4OTIKMTU4ODA5MzIyODoINy4xLjMuMzJCFHYwNC4wNi4wNC1tbC1hbmRyb2lkSICQsEBSCEABAAAAAAAAYILEn9UMaiT7bX/AUyt9C0SXMQW6zymu9esdCIHYB6NLCWf4mE3e30Qb7bByBvttf8BTK3oPCN4BEBQYvuFUKI644a8EggEYN2czb3B3cnJ1WHBJX3NyZEpWc3p4UWRNiAGCxJ/VDJoBIIrk+8s0BSOh41HcPtzj043L9ALt2XDSBg46RB7d1zVjogEEbm9uZagB8AS6AcwCCNYBEI7cxosBGIjcxosBKA4yE3YwNC4wNi4wNC4wMy1idWdmaXg4pLIBYogCCAIQBBoEODY2MiIJMTIzNDU2Nzg5Khg3ZzNvcHdycnVYcElfc3JkSlZzenhRZE0yCCFub3Blcm0hOO/AbEDvwGxIBlDvwGxaCCFub3RzZXQhYg9Bc2lhL1NoYW5naGFpLDhqBXpoX0NOcAiFAQAAAACNAQAAAACVAQAAAACdAQAAAAClAQAAAACtAQAAAACyAQIxNrgBUsABSMgBnqydkLlo0AGerJ2QuWjYAZ6snZC5aOABnqydkLlo6AEB8gEKMjUwNTNSVDQ3Q/oBBVJlZG1pggIKMjUwNTNSVDQ3Q4oCCjI1MDUzUlQ0N0OSAgZYaWFvbWmaAgVSZWRtaaICBVJlZG1psAI+agsI/uKfrw0QAyCQA3IINy4xLjMuMzLCAX17ImNtciI6MTY3NzcyMTYsImNtcjIiOjE2Nzc3MjE2LCJ1bl9oIjoxODc5MTk0MDQwLCJ2cG4iOjAsImtkIjowLCJma2QiOjM2NzI1MTg5NzIsInBkIjotMTg3MjU3MzI0NywiZHluIjoiIiwiZG8iOjAsInRrIjp0cnVlfQ==",
    "xm_rand": 2550441234,
    "gorgon_rand": 7848,
    "gorgon_sha256": "062c11b3dac98fb9badd9d818d2b1e6bf327fb63ce9be2ca7c927f056debddc4",
    "helios_rand": 628136464,
    "helios_sha256": "649822a9b3be92bdea0324dcad07fd57e35461b41cffee4a15211bf70936688a",
    "hash_rand": 2208405135,
    "medusa_sha256": "037edb26cb75b96ebc13648607d4236a3b1bb91a67922b2525e047eb614d89d5"
  },
  {
    "url": "https://example.invalid/aidj-offline?device_id=123456789&version_name=7.1.3.32&sample=2&ts=1700000002&_rticket=1700000002205",
    "body_base64": "H4sIAAAAAAAA/6tWyk9Ly8nMS41Py6woKS1KVbIqKSpNrQUAqgOkbRgAAAA=",
    "timestamp": 1700000002,
    "base_rticket": 1700000002200,
    "selected_offset": 5,
    "f13_hex": "c00fbdea73c3cfb33efe33fcc1881f2cf5eb1d0881d807a34b0967f8984ddedfcc171588",
    "query_prefix_hex": "c00fbdea73c3",
    "proto_base64": "ChD36F/619fcO9YqyHBXz2EYEAYY9qPllRciBDg2NjIqCTEyMzQ1Njc4OTIKMTU4ODA5MzIyODoINy4xLjMuMzJCFHYwNC4wNi4wNC1tbC1hbmRyb2lkSICQsEBSCEABAAAAAAAAYITEn9UMaiTAD73qc8PPsz7+M/zBiB8s9esdCIHYB6NLCWf4mE3e38wXFYhyBsAPvepzw3oPCN4BEBQYvuFUKI644a8EggEYN2czb3B3cnJ1WHBJX3NyZEpWc3p4UWRNiAGExJ/VDJoBIFufCZ/qIMdzMg3e6JtL9fUdJx9ELo2+AfIO3IFUco73ogEEbm9uZagB8AS6AcwCCOgBEI7cxosBGIjcxosBKA4yE3YwNC4wNi4wNC4wMy1idWdmaXg4yqMBYogCCAIQBBoEODY2MiIJMTIzNDU2Nzg5Khg3ZzNvcHdycnVYcElfc3JkSlZzenhRZE0yCCFub3Blcm0hOO/AbEDvwGxIBlDvwGxaCCFub3RzZXQhYg9Bc2lhL1NoYW5naGFpLDhqBXpoX0NOcAiFAQAAAACNAQAAAACVAQAAAACdAQAAAAClAQAAAACtAQAAAACyAQIxNrgBUsABSMgBnqydkLlo0AGerJ2QuWjYAZ6snZC5aOABnqydkLlo6AEB8gEKMjUwNTNSVDQ3Q/oBBVJlZG1pggIKMjUwNTNSVDQ3Q4oCCjI1MDUzUlQ0N0OSAgZYaWFvbWmaAgVSZWRtaaICBVJlZG1psAI+agsI/uKfrw0QAyCQA3IINy4xLjMuMzLCAX17ImNtciI6MTY3NzcyMTYsImNtcjIiOjE2Nzc3MjE2LCJ1bl9oIjoxODc5MTk0MDQwLCJ2cG4iOjAsImtkIjowLCJma2QiOjM2NzI1MTg5NzIsInBkIjotMTg3MjU3MzI0NywiZHluIjoiIiwiZG8iOjAsInRrIjp0cnVlfQ==",
    "xm_rand": 1335098456,
    "gorgon_rand": 53184,
    "gorgon_sha256": "8eed0f81cf2e8a6836113ff7f9fa9fcc7507249c09b06d8623410348f986ff4c",
    "helios_rand": 1820806055,
    "helios_sha256": "ce51c4bdcb59d2b936b5204bb13f52f8c2c2c74d02cacee4eeed604ec59a6ceb",
    "hash_rand": 1514940727,
    "medusa_sha256": "e5e75c08db4c713ab5f44f5a22284bc6ad6a2e300e13f11bddce8b66b3eb6e1d"
  },
  {
    "url": "https://example.invalid/aidj-offline?device_id=123456789&version_name=7.1.3.32&sample=3&ts=1700000003&_rticket=1700000003304",
    "body_base64": "H4sIAAAAAAAA/6tWyk9Ly8nMS41Py6woKS1KVbIqKSpNrQUAqgOkbRgAAAA=",
    "timestamp": 1700000003,
    "base_rticket": 1700000003300,
    "selected_offset": 4,
    "f13_hex": "2b5af2f62f33ae34c03cb096cdd94b59f5eb1d0881d807a34b0967f8984ddedf657b0a96",
    "query_prefix_hex": "2b5af2f62f33",
    "proto_base64": "ChD36F/619fcO9YqyHBXz2EYEAYYoruxoRgiBDg2NjIqCTEyMzQ1Njc4OTIKMTU4ODA5MzIyODoINy4xLjMuMzJCFHYwNC4wNi4wNC1tbC1hbmRyb2lkSICQsEBSCEABAAAAAAAAYIbEn9UMaiQrWvL2LzOuNMA8sJbN2UtZ9esdCIHYB6NLCWf4mE3e32V7CpZyBita8vYvM3oPCN4BEBQYvuFUKI644a8EggEYN2czb3B3cnJ1WHBJX3NyZEpWc3p4UWRNiAGGxJ/VDJoBIFD6EyQv4jTdhT9BGCftrpWO4+7GF7A11A9izucy5fFOogEEbm9uZagB8AS6AcwCCM4BEI7cxosBGIjcxosBKA4yE3YwNC4wNi4wNC4wMy1idWdmaXg4rp8BYogCCAIQBBoEODY2MiIJMTIzNDU2Nzg5Khg3ZzNvcHdycnVYcElfc3JkSlZzenhRZE0yCCFub3Blcm0hOO/AbEDvwGxIBlDvwGxaCCFub3RzZXQhYg9Bc2lhL1NoYW5naGFpLDhqBXpoX0NOcAiFAQAAAACNAQAAAACVAQAAAACdAQAAAAClAQAAAACtAQAAAACyAQIxNrgBUsABSMgBnqydkLlo0AGerJ2QuWjYAZ6snZC5aOABnqydkLlo6AEB8gEKMjUwNTNSVDQ3Q/oBBVJlZG1pggIKMjUwNTNSVDQ3Q4oCCjI1MDUzUlQ0N0OSAgZYaWFvbWmaAgVSZWRtaaICBVJlZG1psAI+agsI/uKfrw0QAyCQA3IINy4xLjMuMzLCAX17ImNtciI6MTY3NzcyMTYsImNtcjIiOjE2Nzc3MjE2LCJ1bl9oIjoxODc5MTk0MDQwLCJ2cG4iOjAsImtkIjowLCJma2QiOjM2NzI1MTg5NzIsInBkIjotMTg3MjU3MzI0NywiZHluIjoiIiwiZG8iOjAsInRrIjp0cnVlfQ==",
    "xm_rand": 1258555151,
    "gorgon_rand": 18201,
    "gorgon_sha256": "4c3425ccfd7f8929fce56654cd6f49a06ad137bb1bbaa293b4ca38dfc36e5a51",
    "helios_rand": 3503854693,
    "helios_sha256": "20816377573ca53ba82bcafcb38b2c8546066ec42491601e108f56f44e5d94ed",
    "hash_rand": 264233881,
    "medusa_sha256": "499b5d4516951d8d7c8f6b07ccd6c420efa5789d58aea2fe27c55ecba1d9a68b"
  }
]''')


def fields(data: bytes) -> dict[int, bytes | int]:
    """Read the small protobuf subset independently of the signing encoder."""
    result = {}
    pos = 0

    def varint() -> int:
        nonlocal pos
        value = shift = 0
        while True:
            item = data[pos]
            pos += 1
            value |= (item & 127) << shift
            if item < 128:
                return value
            shift += 7

    while pos < len(data):
        tag = varint()
        number, wire = tag >> 3, tag & 7
        if wire == 0:
            value = varint()
        elif wire in (2, 5):
            size = varint() if wire == 2 else 4
            value = data[pos:pos + size]
            pos += size
        else:
            raise AssertionError(f'Unexpected wire type {wire}')
        result[number] = value
    return result


def sint(value: int) -> int:
    return (value >> 1) ^ -(value & 1)


class CurrentAiDjSigningTests(unittest.TestCase):
    def test_branch_selection_and_f13_match_java_vectors(self):
        self.assertEqual({v['timestamp'] & 3 for v in JAVA_VECTORS}, {0, 1, 2, 3})
        for vector in JAVA_VECTORS:
            with self.subTest(offset=vector['selected_offset']):
                parts = urlsplit(vector['url'])
                params = dict(parse_qsl(parts.query))
                params.pop('ts')
                params.pop('_rticket')
                body = base64.b64decode(vector['body_base64'])
                with mock.patch.object(signing.time, 'time', return_value=vector['base_rticket'] / 1000):
                    url, chosen = signing._get_params_encrypturl(
                        parts._replace(query='').geturl(), params, {}, data=body,
                        data_type='application/json; charset=UTF-8',
                        khronos=vector['timestamp'], current_jar=True,
                    )
                self.assertEqual(url, vector['url'])
                self.assertEqual(chosen['_rticket'] - vector['base_rticket'], vector['selected_offset'])
                query_sm3 = signing.SM3(url.split('?', 1)[1]).digest()
                self.assertEqual(query_sm3[:6].hex(), vector['query_prefix_hex'])
                actual = signing.hash_f13(
                    query_sm3, hashlib.md5(body).digest(),
                    vector['timestamp'].to_bytes(4, 'little'), vector['timestamp'], current_jar=True,
                )
                self.assertEqual(len(actual), 36)
                self.assertEqual(actual.hex(), vector['f13_hex'])
                # The legacy branch remains available and retains its 20-byte format.
                self.assertEqual(len(signing.hash_f13(
                    query_sm3, hashlib.md5(body).digest(),
                    vector['timestamp'].to_bytes(4, 'little'), vector['timestamp'],
                )), 20)

    def test_complete_current_protobuf_matches_java(self):
        for vector in JAVA_VECTORS:
            expected = base64.b64decode(vector['proto_base64'])
            root = fields(expected)
            env = fields(root[23])
            device = fields(env[12])
            report = fields(env[13])
            with self.subTest(offset=vector['selected_offset']), \
                 mock.patch.object(signing, '_CURRENT_JAR_STARTED_MS', sint(device[25])), \
                 mock.patch.object(signing, '_CURRENT_JAR_SESSION', root[16].decode()), \
                 mock.patch.object(signing.time, 'time', return_value=sint(report[1])), \
                 mock.patch.object(signing.random, 'randint', side_effect=[sint(root[3]), sint(env[1]), sint(env[7])]):
                actual, _, f13 = signing._gen_medusa_proto(
                    vector['url'], {}, {}, base64.b64decode(vector['body_base64']),
                    vector['timestamp'], 'application/json; charset=UTF-8', current_jar=True,
                )
            self.assertEqual(actual, expected)
            self.assertEqual(f13, root[13])
            self.assertEqual(device[5], root[16])
            self.assertEqual([device[field] for field in range(16, 22)], [bytes(4)] * 6)

    def test_final_medusa_envelope_matches_java(self):
        for vector in JAVA_VECTORS:
            root = fields(base64.b64decode(vector['proto_base64']))
            env = fields(root[23])
            device = fields(env[12])
            report = fields(env[13])
            random_values = [sint(root[3]), sint(env[1]), sint(env[7]), vector['hash_rand'], vector['xm_rand']]
            with self.subTest(offset=vector['selected_offset']), \
                 mock.patch.object(signing, '_CURRENT_JAR_STARTED_MS', sint(device[25])), \
                 mock.patch.object(signing, '_CURRENT_JAR_SESSION', root[16].decode()), \
                 mock.patch.object(signing.time, 'time', return_value=sint(report[1])), \
                 mock.patch.object(signing.random, 'randint', side_effect=random_values):
                result = signing._gen_medusa(
                    vector['url'], {}, {}, base64.b64decode(vector['body_base64']),
                    vector['timestamp'], 'application/json; charset=UTF-8', current_jar=True,
                )
            # Match the final Java bytes while retaining only a safe synthetic digest.
            self.assertEqual(hashlib.sha256(base64.b64decode(result)).hexdigest(), vector['medusa_sha256'])

    def test_gorgon_and_helios_match_java(self):
        for vector in JAVA_VECTORS:
            with self.subTest(offset=vector['selected_offset']):
                gorgon = signing._encrypt_gorgon(
                    base64.b64decode(vector['body_base64']), urlsplit(vector['url']).query,
                    vector['timestamp'], vector['gorgon_rand'], 'application/json; charset=UTF-8',
                )
                self.assertEqual(hashlib.sha256(gorgon.encode()).hexdigest(), vector['gorgon_sha256'])
                helios = signing._encrypt_helios(vector['timestamp'], vector['helios_rand'])
                self.assertEqual(hashlib.sha256(base64.b64decode(helios)).hexdigest(), vector['helios_sha256'])

    def test_current_mode_is_default_for_core(self):
        vector = JAVA_VECTORS[1]
        params = dict(parse_qsl(urlsplit(vector['url']).query))
        params.pop('ts')
        params.pop('_rticket')
        body = base64.b64decode(vector['body_base64'])
        with mock.patch.object(signing.time, 'time', return_value=vector['base_rticket'] / 1000):
            headers, url = signing._core_sixgod(
                'https://example.invalid/aidj-offline', params, {}, body,
                {'Content-Type': 'application/json; charset=UTF-8'},
            )
        self.assertEqual(url, vector['url'])
        self.assertEqual(headers['x-khronos'], str(vector['timestamp']))
        self.assertEqual(headers['x-ss-stub'], hashlib.md5(body).hexdigest().upper())
        self.assertTrue(base64.b64decode(headers['x-medusa']))

    def test_explicit_zeros_do_not_change_legacy_encoder(self):
        values = [(1, 0, 'sint32'), (2, 0.0, 'float'), (3, b'', 'bytes')]
        self.assertEqual(signing._proto(values), b'')
        self.assertEqual(signing._proto(values, include_zero=True), bytes.fromhex('080015000000001a00'))


if __name__ == '__main__':
    unittest.main()
