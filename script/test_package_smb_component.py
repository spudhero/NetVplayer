from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest import mock

import package_smb_component as smb


class SMBPackagingTests(unittest.TestCase):
    def repository(self, path, files):
        path.mkdir(parents=True, exist_ok=True)
        subprocess.run(['git', 'init', '-q', str(path)], check=True)
        for name, text in files.items():
            target = path / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text)
        subprocess.run(['git', '-C', str(path), 'add', '.'], check=True)
        subprocess.run(['git', '-C', str(path), '-c', 'user.name=Fixture', '-c',
                        'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture'], check=True)
        return smb.git(path, 'rev-parse', 'HEAD').decode().strip()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.checkout = root / 'checkout'
        self.app = root / 'NetVplayer.app'
        library = self.app / 'Contents/Frameworks/SMB/libAMSMB2.dylib'
        library.parent.mkdir(parents=True)
        library.write_bytes(b'fixture dynamic library')
        amsmb = self.repository(self.checkout, {'LICENSE': 'AMSMB license', 'Sources/Client.swift': 'source'})
        libsmb = self.repository(self.checkout / 'Dependencies/libsmb2',
                                 {'LICENCE-LGPL-2.1.txt': 'libsmb license', 'lib/init.c': 'source'})
        for key, value in [('AMSMB_REVISION', amsmb), ('LIBSMB_REVISION', libsmb)]:
            patcher = mock.patch.object(smb, key, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_packages_both_pinned_sources_and_correct_license_names(self):
        smb.package(self.checkout, self.app)
        notices = self.app / 'Contents/Resources/ThirdPartyLicenses'
        self.assertTrue((notices / 'AMSMB2.LGPL-2.1.txt').is_file())
        self.assertFalse((notices / 'AMSMB2.MIT.txt').exists())
        with tarfile.open(notices / 'SMB-SOURCE.tar.gz') as archive:
            self.assertIn('AMSMB2-4.0.3/Sources/Client.swift', archive.getnames())
            self.assertIn('AMSMB2-4.0.3/Dependencies/libsmb2/lib/init.c', archive.getnames())
        self.assertEqual(smb.audit(self.app)['components'], 2)

    def test_tampered_license_or_source_archive_fails_audit(self):
        for name in ('AMSMB2.LGPL-2.1.txt', 'libsmb2.LGPL-2.1.txt', 'SMB-SOURCE.tar.gz'):
            with self.subTest(name=name):
                smb.package(self.checkout, self.app)
                (self.app / 'Contents/Resources/ThirdPartyLicenses' / name).write_bytes(b'changed')
                with self.assertRaisesRegex(ValueError, 'hash mismatch'):
                    smb.audit(self.app)

    def test_staged_source_change_is_rejected(self):
        (self.checkout / 'Sources/Client.swift').write_text('changed source')
        subprocess.run(['git', '-C', str(self.checkout), 'add', 'Sources/Client.swift'], check=True)
        with self.assertRaises(subprocess.CalledProcessError):
            smb.package(self.checkout, self.app)


if __name__ == '__main__':
    unittest.main()
