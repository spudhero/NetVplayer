#!/usr/bin/env python3
"""Offline packaging controls; the synthetic ABI library is not a media decoder."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT))
import verify_playback_runtime as gate
import build_dash_runtime as dash_builder
import build_dolby_runtime as dolby_builder

GOOD = {'avformat_major': 63, 'demuxers': ['dash', 'hls', 'mov,mp4,m4a'],
        'protocols': ['file', 'http', 'https', 'tcp', 'tls']}


class PolicyTests(unittest.TestCase):
    def test_missing_dash_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'dash'):
            gate.require_capabilities({**GOOD, 'demuxers': ['hls', 'mov,mp4,m4a']})

    def test_loss_of_an_unrelated_baseline_format_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'matroska'):
            gate.require_capabilities(GOOD, {**GOOD, 'demuxers': GOOD['demuxers'] + ['matroska']})

    def test_no_https_cannot_pass_as_a_dash_runtime(self):
        with self.assertRaisesRegex(RuntimeError, 'https'):
            gate.require_capabilities({**GOOD, 'protocols': ['file', 'http', 'tcp', 'tls']})

    def test_wrong_avformat_abi_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'ABI'):
            gate.require_capabilities({**GOOD, 'avformat_major': 62})


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('clang'), 'macOS ABI fixture requires clang')
class PackagingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='netvplayer-format-gate-')
        cls.root = Path(cls.temp.name)
        cls.source = cls.root / 'formats.c'
        cls.source.write_text('''
#include <stddef.h>
#include <stdint.h>
#include <string.h>
struct input { const char *name; };
static struct input inputs[] = {{"dash"}, {"hls"}, {"mov,mp4,m4a"}};
uint32_t avformat_version(void) { return 63u << 16; }
const void *avformat_get_mov_video_tags(void) { return inputs; }
int av_codec_get_id(const void *const *tags, unsigned tag) {
    return tags[0] == inputs && (tag == 0x31637676u || tag == 0x32637662u) ? 1 : 0;
}
const void *avcodec_find_decoder_by_name(const char *name) {
    return strcmp(name, "vvc") == 0 ? inputs : NULL;
}
const void *av_demuxer_iterate(void **opaque) {
    uintptr_t n = (uintptr_t)*opaque;
    if (n == 3) return NULL;
    *opaque = (void *)(n + 1);
    return &inputs[n];
}
const char *avio_enum_protocols(void **opaque, int output) {
    static const char *names[] = {"file", "http", "https", "tcp", "tls"};
    uintptr_t n = (uintptr_t)*opaque;
    if (output || n == 5) return NULL;
    *opaque = (void *)(n + 1);
    return names[n];
}
''')
        cls.native = cls.root / 'abi-fixture.dylib'
        subprocess.run(['clang', '-dynamiclib', '-mmacosx-version-min=14.0', str(cls.source),
                        '-o', str(cls.native)], check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def setUp(self):
        self.output = tempfile.TemporaryDirectory(dir=self.root)
        self.addCleanup(self.output.cleanup)
        self.bundle = Path(self.output.name) / 'fixture.app'
        self.frameworks = self.bundle / 'Contents/Frameworks'
        self.resources = self.bundle / 'Contents/Resources'
        self.frameworks.mkdir(parents=True)
        self.licenses = self.resources / 'ThirdPartyLicenses'
        (self.licenses / 'libmpv/fixture').mkdir(parents=True)
        (self.licenses / 'libmpv/fixture/LICENSE').write_text('Synthetic ABI test only\n')
        shutil.copy2(self.native, self.frameworks / 'libavformat.63.dylib')
        shutil.copy2(self.native, self.frameworks / 'libavcodec.63.dylib')
        # The vendor test copies this file; it never loads or launches it.
        shutil.copy2(self.native, self.frameworks / 'libmpv.2.dylib')
        self.binary = self.frameworks / 'libavformat.63.dylib'
        self.receipt = {'schema': 1, 'packaged_libavformat_sha256': gate.digest(self.binary), 'bytevc2': True}
        self.write('dash-runtime-build.json', self.receipt)
        self.dolby = {'binaries': {self.binary.name: gate.digest(self.binary)},
                      'dashRuntimeBuildSHA256': gate.digest(self.resources / 'dash-runtime-build.json')}
        self.write('dolby-runtime-build.json', self.dolby)
        self.manifest = {'components': [{'formula': 'ffmpeg', 'local_dash_build': self.receipt,
                         'dylibs': [{'name': self.binary.name, 'packaged_sha256': gate.digest(self.binary)}]}]}
        self.write('ThirdPartyLicenses/libmpv-runtime.json', self.manifest)
        (self.licenses / 'libmpv-runtime.md').write_text('Synthetic ABI test only\n')

    def write(self, name, data):
        (self.resources / name).write_text(json.dumps(data))

    def test_native_metadata_query_and_consistent_receipts(self):
        result = gate.verify_bundle(self.bundle)
        self.assertEqual(result['demuxers'], GOOD['demuxers'])
        self.assertTrue(result['bytevc2'])

    def test_bytevc2_receipt_cannot_disagree_with_the_loaded_runtime(self):
        self.receipt['bytevc2'] = False
        self.write('dash-runtime-build.json', self.receipt)
        self.dolby['dashRuntimeBuildSHA256'] = gate.digest(self.resources / 'dash-runtime-build.json')
        self.write('dolby-runtime-build.json', self.dolby)
        with self.assertRaisesRegex(RuntimeError, 'ByteVC2 support differs'):
            gate.verify_bundle(self.bundle)

    def test_pre_dolby_intermediate_does_not_qualify_for_packaging(self):
        (self.resources/'dolby-runtime-build.json').unlink()
        dash_builder.finalize_provenance(self.bundle, self.bundle)
        self.assertEqual(gate.verify_dash_bundle(self.bundle)['demuxers'], GOOD['demuxers'])
        self.assertFalse((self.resources/'dolby-runtime-build.json').exists())
        with self.assertRaises(FileNotFoundError):
            gate.verify_bundle(self.bundle)
        target = Path(self.output.name)/'unqualified.app'
        result = subprocess.run(['bash', str(SCRIPT/'vendor_libmpv.sh'), str(target), '/unused'],
            env=dict(os.environ, NETVPLAYER_LIBMPV_RUNTIME_BUNDLE=str(self.bundle)),
            capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any((target/'Contents/Frameworks').iterdir()))

    def test_pre_dolby_intermediate_keeps_patch_and_manifest_checks(self):
        patch = self.add_source_patch()
        (self.resources/'dolby-runtime-build.json').unlink()
        patch.write_text('Changed source\n')
        with self.assertRaisesRegex(RuntimeError, 'source patch differs'):
            dash_builder.finalize_provenance(self.bundle, self.bundle)
        patch.write_text('Synthetic source patch\n')
        self.manifest['components'][0]['dylibs'][0]['packaged_sha256'] = '0'*64
        self.write('ThirdPartyLicenses/libmpv-runtime.json', self.manifest)
        with self.assertRaisesRegex(RuntimeError, 'license manifest'):
            gate.verify_dash_bundle(self.bundle)

    def test_dash_rebuild_updates_existing_dolby_provenance_without_mutating_baseline(self):
        self.dolby['deployment'] = {self.binary.name: ['14.0']}
        self.write('dolby-runtime-build.json', self.dolby)
        original = (self.resources/'dolby-runtime-build.json').read_bytes()
        target = Path(self.output.name)/'rebuilt.app'
        shutil.copytree(self.bundle, target)
        receipt = {**self.receipt, 'rebuild': True}
        resources = target/'Contents/Resources'
        (resources/'dash-runtime-build.json').write_text(json.dumps(receipt))
        manifest = json.loads(json.dumps(self.manifest))
        manifest['components'][0]['local_dash_build'] = receipt
        (resources/'ThirdPartyLicenses/libmpv-runtime.json').write_text(json.dumps(manifest))
        dash_builder.finalize_provenance(self.bundle, target)
        gate.verify_bundle(target)
        self.assertEqual((self.resources/'dolby-runtime-build.json').read_bytes(), original)
        self.assertNotEqual((resources/'dolby-runtime-build.json').read_bytes(), original)

    def test_cached_pre_dolby_intermediate_is_rechecked(self):
        work = Path(self.output.name)/'work'
        destination = work/'dash-runtime.app'
        shutil.copytree(self.bundle, destination)
        resources = destination/'Contents/Resources'
        (resources/'dolby-runtime-build.json').unlink()
        receipt = {**self.receipt, 'recipe_sha256': gate.digest(SCRIPT/'build_dash_runtime.py'),
                   'original_libavformat_sha256': gate.digest(self.binary)}
        (resources/'dash-runtime-build.json').write_text(json.dumps(receipt))
        manifest = json.loads(json.dumps(self.manifest))
        manifest['components'][0]['local_dash_build'] = receipt
        (resources/'ThirdPartyLicenses/libmpv-runtime.json').write_text(json.dumps(manifest))
        stock = {**GOOD, 'demuxers': ['hls', 'mov,mp4,m4a']}
        with mock.patch.object(dolby_builder, 'capabilities', return_value=stock):
            self.assertEqual(dolby_builder.prepare_dash_runtime(self.bundle, work, Path('/unused')), destination)
            receipt['original_libavformat_sha256'] = '0'*64
            (resources/'dash-runtime-build.json').write_text(json.dumps(receipt))
            manifest['components'][0]['local_dash_build'] = receipt
            (resources/'ThirdPartyLicenses/libmpv-runtime.json').write_text(json.dumps(manifest))
            with self.assertRaisesRegex(RuntimeError, 'input changed'):
                dolby_builder.prepare_dash_runtime(self.bundle, work, Path('/unused'))

    def add_source_patch(self):
        path = self.licenses/'libmpv/ffmpeg/fix.patch'
        path.parent.mkdir()
        path.write_text('Synthetic source patch\n')
        self.receipt['patches'] = [{'name':path.name, 'path':path.relative_to(self.bundle).as_posix(),
                                    'sha256':gate.digest(path)}]
        self.write('dash-runtime-build.json', self.receipt)
        self.dolby['dashRuntimeBuildSHA256'] = gate.digest(self.resources/'dash-runtime-build.json')
        self.write('dolby-runtime-build.json', self.dolby)
        self.write('ThirdPartyLicenses/libmpv-runtime.json', self.manifest)
        return path

    def test_corresponding_dash_source_patch_is_verified(self):
        self.add_source_patch()
        self.assertEqual(gate.verify_bundle(self.bundle)['demuxers'], GOOD['demuxers'])

    def test_missing_dash_source_patch_is_rejected(self):
        self.add_source_patch().unlink()
        with self.assertRaisesRegex(RuntimeError, 'source patch is missing'):
            gate.verify_bundle(self.bundle)

    def test_changed_dash_source_patch_is_rejected(self):
        self.add_source_patch().write_text('Changed source\n')
        with self.assertRaisesRegex(RuntimeError, 'source patch differs'):
            gate.verify_bundle(self.bundle)

    def test_dash_source_patch_cannot_escape_the_bundle(self):
        path = self.add_source_patch()
        external = Path(self.output.name)/'external.patch'
        external.write_bytes(path.read_bytes())
        path.unlink()
        path.symlink_to(external)
        with self.assertRaisesRegex(RuntimeError, 'source patch is missing'):
            gate.verify_bundle(self.bundle)

    def test_replaced_library_is_rejected_even_if_capabilities_still_exist(self):
        self.dolby['binaries'][self.binary.name] = '0' * 64
        self.write('dolby-runtime-build.json', self.dolby)
        with self.assertRaisesRegex(RuntimeError, 'Dolby build receipt'):
            gate.verify_bundle(self.bundle)

    def test_stale_dash_provenance_is_rejected(self):
        self.write('dash-runtime-build.json', {**self.receipt, 'unexpected': True})
        with self.assertRaisesRegex(RuntimeError, 'provenance'):
            gate.verify_bundle(self.bundle)

    def test_deleted_dash_receipt_is_rejected(self):
        (self.resources / 'dash-runtime-build.json').unlink()
        with self.assertRaisesRegex(RuntimeError, 'receipt is missing'):
            gate.verify_bundle(self.bundle)

    def test_license_binary_hash_cannot_refer_to_another_build(self):
        self.manifest['components'][0]['dylibs'][0]['packaged_sha256'] = '0' * 64
        self.write('ThirdPartyLicenses/libmpv-runtime.json', self.manifest)
        with self.assertRaisesRegex(RuntimeError, 'license manifest'):
            gate.verify_bundle(self.bundle)

    def test_license_manifest_cannot_refer_to_another_build(self):
        self.manifest['components'][0]['local_dash_build'] = {}
        self.write('ThirdPartyLicenses/libmpv-runtime.json', self.manifest)
        with self.assertRaisesRegex(RuntimeError, 'license manifest'):
            gate.verify_bundle(self.bundle)

    def test_normal_override_copy_preserves_dash_receipt(self):
        target = Path(self.output.name) / 'package.app'
        exe = target / 'Contents/MacOS/fixture'
        exe.parent.mkdir(parents=True)
        shutil.copy2(self.native, exe)
        result = subprocess.run(['bash', str(SCRIPT / 'vendor_libmpv.sh'), str(target), str(exe)],
            env=dict(os.environ, NETVPLAYER_LIBMPV_RUNTIME_BUNDLE=str(self.bundle)),
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        gate.verify_bundle(target)
        self.assertEqual((target / 'Contents/Resources/dash-runtime-build.json').read_bytes(),
                         (self.resources / 'dash-runtime-build.json').read_bytes())

    def test_bad_override_is_rejected_before_copying_libraries(self):
        self.dolby['binaries'][self.binary.name] = '0' * 64
        self.write('dolby-runtime-build.json', self.dolby)
        target = Path(self.output.name) / 'rejected.app'
        result = subprocess.run(['bash', str(SCRIPT / 'vendor_libmpv.sh'), str(target), '/unused'],
            env=dict(os.environ, NETVPLAYER_LIBMPV_RUNTIME_BUNDLE=str(self.bundle)),
            capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('rejected', result.stderr)
        self.assertFalse(any((target / 'Contents/Frameworks').iterdir()))

    def test_full_app_override_does_not_merge_its_sparkle_into_the_release(self):
        foreign = self.frameworks / 'Sparkle.framework/Resources'
        foreign.mkdir(parents=True)
        (foreign / 'foreign.txt').write_text('Outside the playback runtime')
        target = Path(self.output.name) / 'existing-framework.app'
        resources = target / 'Contents/Frameworks/Sparkle.framework/Versions/A/Resources'
        resources.mkdir(parents=True)
        (resources / 'owned.txt').write_text('Owned by the Release packager')
        link = resources.parents[2] / 'Resources'
        link.symlink_to('Versions/A/Resources')
        exe = target / 'Contents/MacOS/fixture'
        exe.parent.mkdir(parents=True)
        shutil.copy2(self.native, exe)
        result = subprocess.run(['bash', str(SCRIPT / 'vendor_libmpv.sh'), str(target), str(exe)],
            env=dict(os.environ, NETVPLAYER_LIBMPV_RUNTIME_BUNDLE=str(self.bundle)),
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        gate.verify_bundle(target)
        self.assertTrue(link.is_symlink())
        self.assertEqual((link / 'owned.txt').read_text(), 'Owned by the Release packager')
        self.assertFalse((link / 'foreign.txt').exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
